# mc-temp — temporary Minecraft host (NAS-outage playbook)

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

## Operate (the 3 weeks)

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

1. Bring up the NAS stacks (tailscale-traefik, traefik — minecraft still
   stopped). Announce downtime; `docker exec minecraft rcon-cli stop`, then
   `docker compose down` here.
2. Tar `data/`, copy home, replace the stale
   `/mnt/tank/apps/minecraft/data` with it (ownership is already `3009:3009`),
   start the NAS minecraft, test over the tailnet.
3. Revert the `traefik/minecraft.yaml` commit; push; `git pull` on the relay.
   Instant cutback, no DNS.
4. Revert home DNS: tailnet view `mc.mehrtens.com → 100.102.3.49`, re-enable
   the `mc` GUI host override (`10.0.0.22`), `configctl unbound restart`.
5. Remove the `mc-temp` ACL grant + test line. **Delete the Linode** (billing
   stops; the ephemeral tailscale node self-prunes) and `mc-fw`. Keep this
   directory — it's the playbook for the next outage.

## Test matrix

| Test              | Re-runs cloud-init? | Notes                                    |
| ----------------- | ------------------- | ---------------------------------------- |
| Reboot            | No                  | Containers + tailscale return on their own |
| Manual bootstrap  | No                  | `git pull && ./bootstrap.sh` — idempotent |
| Delete + recreate | Yes                 | Re-restore the world from the latest backup; update ACL + relay router to the new `100.x` |
