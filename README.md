# vps-relay

Infrastructure-as-code for a locked-down public-facing relay VPS. A bare Linode
(Debian, Chicago) runs Traefik + a tagged Tailscale node and reverse-proxies
public traffic into home services over the tailnet. First service: a public
**Minecraft Java** server hosted on the home NAS.

The box is disposable: everything here reproduces it from scratch. Secrets live
only in `.env` (gitignored) and in the Linode user-data field — never in git.

---

## Architecture

```
player (off-tailnet)
  → mc.mehrtens.com  (Cloudflare A → VPS public IP)
  → VPS Traefik :25565  (raw TCP, HostSNI(`*`))
  → tailnet dial → 100.102.3.49:25565  (NAS traefik node, tag:home-infra)
  → NAS tailscale serve → NAS Traefik :25565
  → minecraft container
```

**Security model.** The VPS is treated as hostile. It can reach exactly one
thing on the home tailnet — `traefik-node:25565` — enforced by a port-scoped
Tailscale ACL, machine-checked on every policy save. It never terminates TLS
(future HTTPS services pass through by SNI), so a compromised relay holds no
keys and can read no traffic. The host's `sshd` is purged; admin is Tailscale
SSH (`tag:vps-admin`) only, with LISH as break-glass.

**Repo contents**

| File                     | Purpose                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| `bootstrap.sh`           | Idempotent host setup: hardening, Docker, host TS, stack                      |
| `compose.yaml`           | Traefik + tagged Tailscale relay container                                    |
| `traefik.yaml`           | Static config: `:25565` entrypoint, file provider                             |
| `traefik/minecraft.yaml` | Dynamic TCP router → NAS traefik node                                         |
| `cloud-init.yaml`        | User-data: clone + inject secrets + run bootstrap (NOT committed; holds keys) |
| `.env` / `.env.example`  | Two Tailscale auth keys (`.env` gitignored)                                   |

---

## External prerequisites (live outside this repo)

These persist across VPS rebuilds. Set them up once.

### 1. Tailscale auth keys

Two keys, from the Tailscale admin console → Settings → Keys. Both:
**Reusable**, **Ephemeral**, **Pre-approved**.

| Key                | Tag             | Used by                          |
| ------------------ | --------------- | -------------------------------- |
| `TS_AUTHKEY_ADMIN` | `tag:vps-admin` | `bootstrap.sh` (host node)       |
| `TS_AUTHKEY_RELAY` | `tag:vps-relay` | `compose.yaml` (relay container) |

Reusable so rebuilds re-auth without minting new keys; ephemeral so destroyed
nodes self-prune; pre-approved so a node never stalls awaiting manual approval.

The matching ACL must already grant `tag:vps-relay → traefik-node:25565` and
nothing else (the data-plane lockdown). The tailnet policy lives separately
from this repo.

### 2. Cloud Firewall `relay-fw`

A persistent Linode resource — created once, selected at every VPS create.
See **Recreating `relay-fw`** below if it's ever deleted. Day to day you just
pick it in the create flow.

### 3. Cloudflare DNS

A record `mc.mehrtens.com` → VPS public IP, **DNS only (grey cloud)**. See
**DNS** below.

### 4. This repo, public on GitHub

`cloud-init.yaml` clones it by HTTPS. No secrets are committed, so public is
fine. Update the clone URL in `cloud-init.yaml` to match.

---

## Secrets — `.env`

Copy the example and fill in both keys:

```
cp .env.example .env
# edit .env — paste the two tskey-auth-... values
```

`.env` is gitignored. `docker compose` auto-loads it for `${TS_AUTHKEY_RELAY}`
interpolation; `bootstrap.sh` sources it for `${TS_AUTHKEY_ADMIN}`.

---

## Provision a fresh VPS (canonical workflow)

1. Fill `cloud-init.yaml`: set the GitHub clone URL and paste both real keys
   into the `write_files` `.env` block. (This filled-in file holds secrets —
   keep it local, don't commit it.)
2. Validate: `cloud-init schema --config-file cloud-init.yaml`
3. Linode → Create Linode:
   - Debian, Chicago region, Nanode 1 GB.
   - **Firewall: select `relay-fw`** (attaches at create).
   - **User Data:** paste the contents of `cloud-init.yaml`.
   - Create.
4. Wait ~3–5 min, then **don't SSH** — test from off-tailnet (see Verification).

That's it. No post-create steps in the normal case.

> Fallback: if your account's networking mode won't let a firewall attach at
> create (newer "Linode Interfaces" mode), attach `relay-fw` via the Linode's
> Network tab after create. Recent creates have attached at create time.

---

## Rebuild (same IP)

Linode → the Linode → **Rebuild**. Provide Debian + the same user-data. The OS
is reinstalled, cloud-init re-runs, the **public IP is retained** (so Cloudflare
needs no change). Old ephemeral nodes self-prune; new ones re-register. Use this
for a clean OS reset without churning DNS.

## Reboot

A plain reboot does **not** re-run cloud-init. Containers return via
`restart: unless-stopped`; the host Tailscale node and the relay container
re-auth from persisted state. Expect a few seconds of Traefik dial errors
before the tailnet comes up, then steady state. Nothing to do.

## Manual bootstrap (on a live box)

Over Tailscale SSH (`ssh root@vps-relay`), in `/root/vps-relay`:

```
git pull
./bootstrap.sh
```

Idempotent — converges to the desired state. Use after editing repo files on
the live box (fast iteration loop).

---

## Recreating `relay-fw` (only if deleted)

1. Create a firewall from the **Public** template; name it `relay-fw`.
2. **Delete the template's `accept-inbound-ssh` (TCP 22) rule.** Public SSH
   stays closed — admin is Tailscale SSH only and `sshd` is purged. Leaving :22
   open contradicts the design.
3. Keep `accept-inbound-icmp` (ping — liveness, negligible risk).
4. Add inbound `accept-inbound-minecraft`: TCP `25565`, sources
   `0.0.0.0/0` + `::/0`, Accept.
5. Default inbound **Drop**; default outbound **Accept** (relay needs egress
   for Tailscale coordination/DERP + the tailnet dial).

Final inbound: ICMP, TCP 25565, no :22.
_(Future HTTPS: add TCP `8443` the same way for PhotoPrism etc.)_

---

## DNS

Cloudflare A record, zone `mehrtens.com`:

| Name | Type | Value         | Proxy                     |
| ---- | ---- | ------------- | ------------------------- |
| `mc` | A    | VPS public IP | **DNS only** (grey cloud) |

**Grey cloud is mandatory.** Cloudflare's proxy only handles HTTP/HTTPS — it
cannot proxy Minecraft's raw TCP on :25565. Orange cloud breaks it; DNS-only
returns the real VPS IP and steps out of the path. (A future HTTPS service
_could_ go orange — Minecraft cannot.) IPv4 only; no AAAA unless the Linode has
confirmed public IPv6 that `relay-fw` passes on 25565.

### Resolution paths (the three legs)

| Path             | Resolver             | `mc.mehrtens.com` →           |
| ---------------- | -------------------- | ----------------------------- |
| Public (off-net) | Cloudflare           | VPS public IP                 |
| Tailnet (away)   | Unbound tailnet view | `100.102.3.49` (traefik node) |
| Local (at home)  | Unbound default view | `10.0.0.22` (LAN)             |

### ⚠ After a full destroy/recreate

A **Rebuild** keeps the IP. A full **destroy/recreate** assigns a NEW public IP:

- Update the Cloudflare `mc` A record to the new IP.
- Unbound tailnet/LAN entries are unaffected (they point at NAS nodes).

---

## Verification

After any provision/rebuild, from a machine **not on the tailnet** (a friend, or
your phone on cellular with Tailscale off):

```
dig mc.mehrtens.com +short        # → VPS public IP (skip right after a new IP)
nc -zv <VPS_public_IP> 25565      # → succeeded   (tests the path by IP)
nc -zv mc.mehrtens.com 25565      # → succeeded   (tests the name too)
```

Then over the tailnet (`ssh root@vps-relay`):

```
docker compose ps                 # both containers Up
docker compose logs tailscale-relay | grep -i tun   # → tailscale0 (NOT userspace)
cat /var/log/bootstrap.log        # clean run; sshd purged (fresh boots)
```

In the Tailscale admin console: `vps-relay` (admin) and `vps-relay-data`
(relay) both present and correctly tagged; no stale duplicates (ephemeral
nodes self-prune). The `tag:vps-relay` data-plane ACL test still passes on save.

### Test matrix

| Test                  | Re-runs cloud-init? | IP      | DNS action         |
| --------------------- | ------------------- | ------- | ------------------ |
| Reboot                | No                  | Same    | None               |
| Manual `bootstrap.sh` | No                  | Same    | None               |
| Rebuild (user-data)   | Yes                 | Same    | None               |
| Delete + recreate     | Yes                 | **New** | Update `mc` record |

---

## Future: HTTPS services (PhotoPrism)

1. Uncomment the `websecure: ":443"` entrypoint in `traefik.yaml`.
2. Add `traefik/photoprism.yaml`: a TCP router on `websecure` with
   `HostSNI(\`photos.mehrtens.com\`)`, `tls.passthrough: true`, →
`100.102.3.49:8443`.
3. Grant `tag:vps-relay → traefik-node:8443` in the tailnet ACL; extend the
   data-plane deny test accordingly.
4. Add `8443/tcp` to `relay-fw`.
5. NAS side: a `:8443` Traefik entrypoint + matching `tailscale serve --tcp=8443`.
6. Cloudflare `photos` record → VPS IP (grey cloud — passthrough, VPS holds no cert).
