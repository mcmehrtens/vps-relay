# mc-temp — temporary Minecraft host (NAS-outage playbook)

**Status: dormant — nothing is deployed.** Last activation 2026-07-22 →
2026-08-29 (NAS hardware move): Minecraft ran on a temporary Chicago Linode
while the NAS was down, then came home. The Linode and the `mc-fw` firewall are
deleted and the `mc-temp` ACL entries are removed; the relay's Minecraft route
points at `100.102.3.49:25565` again. This directory is kept as the playbook
for the next outage: `compose.yaml`, `cloud-init.yaml`, and `bootstrap.sh` are
ready to use as-is — only the pinned versions and the auth key need a look.

A disposable Linode that hosts the Minecraft server itself while the NAS is
down. The public face doesn't change: `mc.mehrtens.com` still resolves to the
relay VPS, the relay's Traefik still listens on `:25565` — only the *backend*
of the relay's one Minecraft route moves from the NAS traefik node to this box.
Players notice nothing; cutover and cutback are each a one-line change.

```
player → mc.mehrtens.com  (Cloudflare A → relay VPS IP, unchanged)
       → relay Traefik :25565  (unchanged)
       → tailnet dial → mc-temp (100.x):25565      ← the one changed line
       → minecraft container (this compose)
```

Both Linodes live in Chicago, so the relay→mc-temp hop is intra-datacenter
(sub-ms, direct WireGuard — no DERP risk between two public-IP nodes in one DC).

**Plan:** `g8-dedicated-8-2` (G8 Dedicated 8GB: 2× 5th-gen EPYC vCPU, 8G RAM,
82G disk, ~$0.11/hr). Chosen for single-thread speed — Paper's tick loop
(entities, mob farms) is single-threaded, so core generation matters more than
core count. G8 has no bundled transfer; egress bills at $0.005/GB, which for a
2-player server is ~$1–2 over three weeks. `MEMORY=5G` (not the NAS's 6G): the
heap must share 8G with ~1G of JVM overhead + OS/Docker/Tailscale, and 5G is
already far more than 2 players need.

**Security model.** Same posture as the relay, minus public services entirely:
cloud firewall `mc-fw` allows **no public inbound at all** (ICMP only) — game
traffic arrives over the tailnet from the relay, which the ACL allows to reach
exactly `mc-temp:25565`. Host `sshd` is purged; admin is Tailscale SSH
(`tag:vps-admin`, same reusable key as the relay host) with LISH as
break-glass. RCON is never published; use `docker exec minecraft rcon-cli`.

---

## Provision

### 0. Before the NAS goes down

- Stop the minecraft container; archive `/mnt/tank/apps/minecraft/data`
  (tar, so ownership survives); copy the archive to the Mac.
- Capture `RCON_PASSWORD` from `/mnt/tank/apps/minecraft/.env` (optional — a
  fresh value works too; RCON is internal-only).

### 1. Cloud Firewall `mc-fw` (create once)

- Inbound: keep `accept-inbound-icmp` only. **No :22, no :25565** — nothing
  public reaches this box.
- Default inbound **Drop**; default outbound **Accept**.

### 2. Create the Linode

1. Fill `cloud-init.yaml`: paste the real `TS_AUTHKEY_ADMIN` (same key as the
   relay's) and `RCON_PASSWORD` into the `write_files` block. Keep the
   filled-in copy local — never commit it.
2. Ensure this directory is **pushed to GitHub first** (cloud-init clones the
   public repo).
3. Linode → Create: Debian, **Chicago**, plan **G8 Dedicated 8GB**
   (`g8-dedicated-8-2`), firewall `mc-fw`, paste the filled-in cloud-init as
   User Data. Create.
4. Wait ~3–5 min; `mc-temp` appears in the Tailscale admin console tagged
   `tag:vps-admin`. Note its `100.x` address — it's needed for the ACL and the
   relay router.

### 3. Restore the world

From the Mac, over the tailnet:

```
rsync -av --progress ~/tmp/minecraft-data.tar.xz root@mc-temp:/root/vps-relay/mc-temp/
ssh root@mc-temp
  cd /root/vps-relay/mc-temp
  tar -xJpf minecraft-data.tar.xz    # archive carries the data/ prefix → extracts into place
  chown -R 3009:3009 data            # tar-as-root already preserved this; belt & suspenders
  docker compose up -d
  docker compose logs -f minecraft   # wait for "Done"
```

The restored `whitelist.json` / `ops.json` carry both players — the env vars
only re-assert what's already there. Do **not** start the container before the
restore: an empty `data/` would generate a fresh world.

**Pre-cutover test:** from a tailnet Mac, Minecraft → Direct Connect →
`<mc-temp-100.x>:25565`. Walk around; check `docker stats` while near the farms.

### 4. Cutover (relay repoint)

1. **Tailnet ACL:** add a `hosts` alias for `mc-temp` = its `100.x`, grant
   `tag:vps-relay → mc-temp:25565`, and extend the relay ACL *test* to accept
   it (keep every existing deny). The `traefik-node` grants can stay — that
   node is off anyway.
2. **This repo:** in `traefik/minecraft.yaml`, change the service address
   `100.102.3.49:25565` → `<mc-temp-100.x>:25565`. Commit, push.
3. **Relay:** `ssh root@vps-relay`, `cd /root/vps-relay && git pull`. Traefik's
   file provider (`watch: true`) hot-reloads — no restart.
4. **Home DNS (OPNsense Unbound) — don't skip this.** `mc.mehrtens.com` has
   split-horizon entries pointing at the NAS leg, which during the outage
   *accepts TCP and then hangs* (the NAS-side `serve :25565` still listens but
   its backend is stopped). In the tailnet view
   (`/usr/local/etc/unbound.opnsense.d/tailnet-view.conf`) set
   `mc.mehrtens.com → <mc-temp-100.x>`; in the GUI, **disable** the `mc` host
   override (LAN clients then resolve publicly → relay). Then
   `configctl unbound restart`. Symptom if forgotten: your own devices can't
   join while off-tailnet players are fine — `dig mc.mehrtens.com +short`
   from the failing device tells you instantly.
5. **Verify off-tailnet** (phone on cellular, Tailscale off):
   `nc -zv mc.mehrtens.com 25565`, then a real join from both players.

---

## Operate (while it's live)

- **Backups:** the `backup` sidecar tars `/data` every 6h (RCON-coordinated
  `save-off`/`save-on`), 2-day retention, skipped while nobody plays. Weekly,
  pull a copy off-box from the Mac:
  `rsync -av root@mc-temp:/root/vps-relay/mc-temp/backups/ ~/mc-temp-backups/`
- **Patching:** unattended-upgrades handles the OS. Leave the pinned
  minecraft/Paper versions alone — no world-format drift before it goes home.
- **Console:** `ssh root@mc-temp`, then `docker exec minecraft rcon-cli`.
- The relay's `photos`/`auth` routers fail their dials while the NAS is down —
  expected, ignore.

## Cutback (NAS returns)

Order matters: the world moves home and is **proven working on the NAS before**
the relay repoints, so a bad restore never becomes public downtime. mc-temp
keeps serving players right up until step 4 — nothing before it is
time-critical, and every step before it is reversible by just restarting the
mc-temp stack.

### 1. Pre-flight (nothing stops yet)

- NAS stacks up (`tailscale-traefik`, `traefik`), `minecraft` still **stopped**.
- The NAS `compose.yaml` still pins what the world was frozen at — image
  `itzg/minecraft-server:2026.7.2-java25`, `VERSION=26.2`, no stale
  `PAPER_BUILD`. Same-or-newer is fine; **never older**: Paper refuses to open a
  world a newer build has already touched, and there is no downgrade path.
- Free space on `/mnt/tank` ≥ 3× world size (archive + extract + the stale copy
  kept as a fallback).
- Tailscale up on the Mac; `nas`, `traefik`, and `router` all online.

### 2. Freeze and archive the world on mc-temp

```
ssh root@mc-temp
  cd /root/vps-relay/mc-temp
  docker exec minecraft rcon-cli list     # confirm nobody is mid-session
  docker exec minecraft rcon-cli say "Server moving home — back in ~15 min"
  docker compose down -t 120              # graceful stop; takes the sidecar too
  docker ps -a                            # both containers gone
  ls -la data/world/level.dat             # mtime = just now → the save landed
  tar -cpf - data | xz -T0 -3 > minecraft-data-$(date +%F).tar.xz
  sha256sum minecraft-data-*.tar.xz
```

**Use `compose down -t 120`, not `rcon-cli stop`.** With `restart:
unless-stopped`, an rcon `stop` exits the JVM 0 and Docker immediately restarts
the container — you get a *running* server and think you stopped it. `compose
down` SIGTERMs `mc-server-runner`, which issues the in-game stop and waits for
the save; `-t 120` keeps Docker's 10s default from SIGKILLing a large world
mid-flush. Verify by `level.dat`'s mtime, not by the log tail — a restart
interleaves shutdown-save lines and startup lines, which reads very confusingly.
Never tar a running world.

### 3. Carry it home (via the Mac, then to the NAS)

Two hops instead of one on purpose: it leaves an off-box copy on the Mac, and
it needs no mc-temp↔NAS ACL grant.

```
# on the Mac
rsync -av --progress root@mc-temp:/root/vps-relay/mc-temp/minecraft-data-*.tar.xz ~/tmp/
shasum -a 256 ~/tmp/minecraft-data-*.tar.xz     # must match step 2
rsync -av --progress ~/tmp/minecraft-data-*.tar.xz <nas>:/mnt/tank/apps/minecraft/
```

### 4. Restore on the NAS, then flip the relay

```
# on the NAS, minecraft still stopped
cd /mnt/tank/apps/minecraft
mv data data.stale-$(date +%F)      # keep the pre-outage world as a fallback
tar -xJpf minecraft-data-*.tar.xz   # archive carries the data/ prefix
chown -R 3009:3009 data
docker compose up -d minecraft
docker compose logs -f minecraft    # wait for "Done"
```

Test it over the tailnet/LAN first — Direct Connect to `10.0.0.22:25565` — and
actually walk around: spawn, both players' bases, a mob farm. Only then:

1. Revert `traefik/minecraft.yaml` to `100.102.3.49:25565`; commit; push.
2. `ssh root@vps-relay`, `cd /root/vps-relay && git pull`. Traefik's file
   provider (`watch: true`) hot-reloads — no restart, no DNS change.
3. Verify off-tailnet (phone on cellular, Tailscale off): `nc -zv
   mc.mehrtens.com 25565`, then a **real join** — see the SLP gotcha below.

Keep `data.stale-*` and the tarball until a full play session has gone by; drop
the stale copy after.

### 5. Revert home DNS (OPNsense)

- Tailnet view (`/usr/local/etc/unbound.opnsense.d/tailnet-view.conf`):
  `mc.mehrtens.com → 100.102.3.49`. Leave its `local-zone … static` line alone —
  that's the AAAA suppression, not the address.
- Re-enable the `mc` GUI host override (`10.0.0.22`), then `configctl unbound
  restart`.
- If the tailnet `mehrtens.com` split-DNS route was deleted during the outage
  (a documented workaround below), re-add it → the `router` node
  (`fd7a:115c:a1e0::6601:e460`).
- Verify from three places: on the tailnet `dig mc.mehrtens.com +short` →
  `100.102.3.49` and `dig AAAA` → NODATA; on the LAN → `10.0.0.22`;
  off-tailnet → the relay's public IP.

### 6. Decommission

Only after a real play session on the NAS server has gone by.

- Keep the final tarball on the Mac (plus `~/mc-temp-backups/`) — that's the
  insurance that makes deleting the box safe.
- **Delete the Linode** — billing only stops on delete; a powered-off instance
  still bills. Then delete the `mc-fw` cloud firewall.
- Tailnet ACL: remove the `hosts` alias `mc-temp`, the `tag:vps-relay →
  mc-temp:25565` grant, the member rule, and the test lines. Keep every existing
  deny and the `traefik-node` grants.
- **Do not revoke `TS_AUTHKEY_ADMIN`** — the relay host shares that key.
- Confirm `mc-temp` is gone from the Tailscale admin console (ephemeral nodes
  self-prune) and from the Linode billing page.
- Update the status banner at the top of this file.

## Gotchas (all of these cost real time)

- **A bare TCP connect proves nothing.** Traefik accepts on `:25565` before it
  dials the backend, so `nc -zv` succeeds even when the server behind it is
  dead. Symptom: "connects, then hangs." Always finish with a real
  Server-List-Ping — the multiplayer list showing MOTD + player count — or an
  actual join.
- **Debug DNS first, always.** `dig mc.mehrtens.com +short` from the failing
  device answers most "can't reach server" reports in one command. A stale `mc`
  entry pointing at a down NAS leg is indistinguishable from a server problem
  until you look. But from inside the LAN you cannot see the *public* answer:
  OPNsense NAT-redirects outbound `:53`, so even `dig @1.1.1.1` is answered by
  Unbound's LAN view — during cutback that returned `10.0.0.22` and looked like
  a private address had leaked into public DNS. The tell is `dig @1.1.1.1 CH TXT
  id.server` coming back empty. Get the real answer over DoH, which uses `:443`
  and can't be intercepted:

  ```
  curl -s -H 'accept: application/dns-json' \
    'https://cloudflare-dns.com/dns-query?name=mc.mehrtens.com&type=A'
  ```
- **The tailnet split-DNS route for `mehrtens.com` points at the `router`
  node.** If OPNsense is down — which it is during a whole-homelab outage —
  every tailnet device with `accept-dns` fails to resolve *any* `mehrtens.com`
  name, and Minecraft just says "can't reach server" while the server is
  perfectly healthy. Workarounds while it's down: connect to the MagicDNS name
  (`mc-temp.opah-alligator.ts.net`), or delete the `mehrtens.com` split-DNS
  route so names fall through to public DNS → the relay. Re-add it at cutback.
  Diagnose with `tailscale dns status` + `tailscale status`.
- **AAAA leaks past the tailnet view.** The public names carry intentional AAAA
  records (IPv6-only cellular). Without a per-name `local-zone … static` entry,
  a dual-stack tailnet device resolves the AAAA and takes the public relay path
  instead of the direct one. Any new name in the tailnet view needs *both* a
  `local-zone … static` and a `local-data` line.

- **Test the relay→NAS hop from inside the relay's netns, not from the relay
  host.** They are two different tailnet nodes with different grants: the host
  is `vps-relay` (`tag:vps-admin`), while the ACL grant belongs to
  `vps-relay-data` (`tag:vps-relay`), which lives in the Traefik container's
  network namespace (`network_mode: service:traefik`). A probe from the host —
  or from your Mac — is ACL-denied and times out, which is indistinguishable
  from a dead backend and will send you diagnosing the NAS for an hour. Test it
  the way Traefik actually dials it:

  ```
  PID=$(docker inspect -f '{{.State.Pid}}' traefik)
  nsenter -t $PID -n python3 - 100.102.3.49:25565   # SLP, not just a TCP connect
  ```

## Test matrix

| Test              | Re-runs cloud-init? | Notes                                    |
| ----------------- | ------------------- | ---------------------------------------- |
| Reboot            | No                  | Containers + tailscale return on their own |
| Manual bootstrap  | No                  | `git pull && ./bootstrap.sh` — idempotent |
| Delete + recreate | Yes                 | Re-restore the world from the latest backup; update ACL + relay router to the new `100.x` |
