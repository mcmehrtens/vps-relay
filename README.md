# vps-relay

Infrastructure-as-code for a locked-down public-facing relay VPS. A bare Linode
(Debian, Chicago) runs Traefik + a tagged Tailscale node and reverse-proxies
public traffic into home services over the tailnet. Two services today: a public
**Minecraft Java** server and **Immich** (`photos.mehrtens.com`), both hosted on
the home NAS.

The box is disposable: everything here reproduces it from scratch. Secrets live
only in `.env` (gitignored) and in the Linode user-data field — never in git.

---

## Architecture

**Minecraft** (raw TCP, no TLS):

```
player (off-tailnet)
  → mc.mehrtens.com  (Cloudflare A → VPS public IP)
  → VPS Traefik :25565  (raw TCP, HostSNI(`*`))
  → tailnet dial → 100.102.3.49:25565  (NAS traefik node, tag:home-infra)
  → NAS tailscale serve → NAS Traefik :25565
  → minecraft container
```

**Immich** (TLS passthrough, SNI-routed):

```
family (off-tailnet)
  → photos.mehrtens.com  (Cloudflare A → VPS public IP, grey cloud)
  → VPS Traefik :443  (TCP, HostSNI(`photos.mehrtens.com`), tls.passthrough)
  → tailnet dial → 100.102.3.49:8443  (NAS traefik node, tag:home-infra)
  → NAS tailscale serve --tcp=8443 → NAS Traefik :8443 ("public" entrypoint)
  → immich_server:2283  ← TLS terminates HERE, on the NAS, with the LE cert
```

The two never interact: Minecraft on its own `:25565` entrypoint with
`HostSNI(*)`, Immich on `:443` matched by exact SNI. The public port for Immich
is **`:443`**; `:8443` is only the NAS-side backend the relay dials over the
tailnet — it never appears in a URL or a firewall rule.

**Security model.** The VPS is treated as hostile. It can reach exactly two
ports on one home tailnet node — `traefik-node:25565` (Minecraft) and
`traefik-node:8443` (Immich) — and nothing else, enforced by a port-scoped
Tailscale ACL, machine-checked on every policy save. It never terminates TLS
(Immich passes through by SNI; Minecraft is raw TCP), so a compromised relay
holds no keys and can read no traffic. On the NAS side, `:8443` is a dedicated
Traefik entrypoint that serves **Immich only** (entrypoint scoping), so even a
forged-SNI request can't reach `auth`/`watch`/the dashboard — a second,
independent layer beneath the ACL. The host's `sshd` is purged; admin is
Tailscale SSH (`tag:vps-admin`) only, with LISH as break-glass.

**Repo contents**

| File                     | Purpose                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| `bootstrap.sh`           | Idempotent host setup: hardening, Docker, host TS, stack                      |
| `compose.yaml`           | Traefik + tagged Tailscale relay container                                    |
| `traefik.yaml`           | Static config: `:25565` + `:443` entrypoints, file provider                   |
| `traefik/minecraft.yaml` | Dynamic TCP router (Minecraft) → NAS traefik node `:25565`                    |
| `traefik/immich.yaml`    | Dynamic TCP router (Immich, SNI passthrough) → NAS traefik node `:8443`       |
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
`traefik-node:8443` and nothing else (the data-plane lockdown). The tailnet
policy lives separately from this repo.

### 2. Cloud Firewall `relay-fw`

A persistent Linode resource — created once, selected at every VPS create.
See **Recreating `relay-fw`** below if it's ever deleted. Day to day you just
pick it in the create flow.

### 3. Cloudflare DNS

A records `mc.mehrtens.com` and `photos.mehrtens.com` → VPS public IP, both
**DNS only (grey cloud)**. See **DNS** below.

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
5. Add inbound `accept-inbound-https`: TCP `443`, sources `0.0.0.0/0` + `::/0`,
   Accept. (Public port for Immich. The NAS-side `:8443` backend is reached over
   the tailnet and is **not** a firewall rule.)
6. Default inbound **Drop**; default outbound **Accept** (relay needs egress
   for Tailscale coordination/DERP + the tailnet dial).

Final inbound: ICMP, TCP 25565, TCP 443, no :22.

---

## DNS

Cloudflare A records, zone `mehrtens.com`:

| Name     | Type | Value         | Proxy                     |
| -------- | ---- | ------------- | ------------------------- |
| `mc`     | A    | VPS public IP | **DNS only** (grey cloud) |
| `photos` | A    | VPS public IP | **DNS only** (grey cloud) |

**Grey cloud is mandatory for both.** Cloudflare's proxy only handles
HTTP/HTTPS, so it cannot proxy Minecraft's raw TCP on :25565 at all. For Immich
the reason differs but the answer is the same: the design is end-to-end TLS
**passthrough** with the cert living on the NAS and the VPS holding nothing —
orange cloud would terminate TLS at Cloudflare's edge and break that chain. So
both stay DNS-only, returning the real VPS IP and stepping out of the path.
IPv4 only; no AAAA unless the Linode has confirmed public IPv6 that `relay-fw`
passes on the relevant ports.

### Resolution paths (the three legs)

Both `mc.mehrtens.com` and `photos.mehrtens.com` resolve identically (they share
the relay):

| Path             | Resolver             | Resolves to                   |
| ---------------- | -------------------- | ----------------------------- |
| Public (off-net) | Cloudflare           | VPS public IP                 |
| Tailnet (away)   | Unbound tailnet view | `100.102.3.49` (traefik node) |
| Local (at home)  | Unbound default view | `10.0.0.22` (LAN)             |

On the tailnet and at home the **service** differs by port behind that one IP
(Minecraft `:25565`, Immich `:443` via the normal private entrypoint); the
relay's `:8443` backend is used only by the VPS, never by tailnet/LAN clients.

### ⚠ After a full destroy/recreate

A **Rebuild** keeps the IP. A full **destroy/recreate** assigns a NEW public IP:

- Update **both** Cloudflare A records (`mc` and `photos`) to the new IP.
- Unbound tailnet/LAN entries are unaffected (they point at NAS nodes).

---

## Verification

After any provision/rebuild, from a machine **not on the tailnet** (a friend, or
your phone on cellular with Tailscale off):

```
dig mc.mehrtens.com +short        # → VPS public IP (skip right after a new IP)
nc -zv <VPS_public_IP> 25565      # → succeeded   (tests the path by IP)
nc -zv mc.mehrtens.com 25565      # → succeeded   (tests the name too)

dig photos.mehrtens.com +short    # → VPS public IP
nc -zv photos.mehrtens.com 443    # → succeeded   (firewall + name)
curl -sI https://photos.mehrtens.com/   # → HTTP/2 200 (full passthrough chain, LE cert)
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

## HTTPS services (Immich) — implemented

`photos.mehrtens.com` is live via TLS passthrough. The original plan named
PhotoPrism and a public `:8443`; what shipped is Immich, and the public port is
`:443` (`:8443` is only the NAS-side backend). Recorded here as built:

1. **VPS `traefik.yaml`:** add the `websecure: ":443"` entrypoint, address only —
   **no `certResolver`/TLS** (passthrough terminates nothing).
2. **VPS `traefik/immich.yaml`:** TCP router on `websecure`, rule
   `HostSNI(\`photos.mehrtens.com\`)`, `tls.passthrough: true`, service →
   `100.102.3.49:8443`.
3. **VPS `compose.yaml`:** publish `443:443` (alongside `25565:25565`).
4. **Tailnet ACL:** `tag:vps-relay → traefik-node:25565` **and**
   `traefik-node:8443`; relay test accepts `:8443`, still denies `traefik:443` /
   `nas:443` / `router:53`.
5. **`relay-fw`:** inbound TCP `443` (the public port; `:8443` is tailnet-only,
   never a firewall rule).
6. **NAS side:** a scoped `public` entrypoint on `:8443` (Immich router only,
   carrying the upload timeouts) + `tailscale serve --bg --tcp=8443
   tcp://127.0.0.1:8443` on the `tailscale-traefik` node. See the home
   remote-access reference for the NAS-side detail.
7. **Cloudflare:** `photos` A → VPS IP, grey cloud (passthrough, VPS holds no
   cert).

Adding a **third** SNI-routed HTTPS service later reuses this exact pattern: a
new `HostSNI` passthrough router on the shared VPS `:443` entrypoint → a
dedicated NAS backend port, a matching `tailscale serve --tcp=<port>`, the ACL
grant + deny-test line, and a grey-cloud Cloudflare record. The VPS `:443`
entrypoint is shared across all SNI-routed HTTPS services; only the dynamic
router file and the NAS backend port are per-service.
