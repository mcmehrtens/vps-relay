#!/usr/bin/env bash
set -euo pipefail

# changes to the correct directory (mc-temp/)
cd "$(dirname "$(readlink -f "$0")")"

# Load secrets (TS_AUTHKEY_ADMIN, RCON_PASSWORD) from the gitignored .env if present
if [[ -f .env ]]; then
    set -a
    source ./.env
    set +a
fi

### Base hardening ###
cat /etc/os-release

apt update && apt full-upgrade -y

# curl + ca-certificates: required by Docker's repo setup below (key fetch + TLS)
# git: lets bootstrap.sh run standalone; under cloud-init the clone already
#      installed it, so this is a harmless no-op there.
# rsync + xz-utils: world restore (tar.xz upload/extract) + weekly backup pulls
apt install -y ca-certificates curl git rsync xz-utils

# automatic security updates, no auto-reboot
apt install -y unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    >/etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades

timedatectl set-timezone America/Chicago
hostnamectl set-hostname mc-temp

### Docker: official repo + engine ###
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Smoke tests: only when run interactively (a TTY on stdout). Skipped under
# cloud-init (stdout is piped to tee) so a transient registry hiccup pulling
# hello-world can't abort the whole bootstrap before the stack + sshd purge.
if [[ -t 1 ]]; then
    docker run --rm hello-world
fi
docker compose version

### Tailscale (host-level admin node) ###
# Host install (NOT a container): this node must be able to disable the host's
# own sshd, so Tailscale lives at the host level. Tagged tag:vps-admin (same
# reusable key as the relay host), reachable only via Tailscale SSH (--ssh).
# LISH is break-glass. The minecraft container needs no tailscale of its own:
# tailnet traffic to <mc-temp>:25565 lands on the host and hits the published
# container port.

# Fail loudly if the auth key wasn't loaded (reusable + ephemeral + tag:vps-admin)
: "${TS_AUTHKEY_ADMIN:?TS_AUTHKEY_ADMIN not set — populate .env from .env.example before running}"

# Install only if absent — keeps bootstrap.sh re-runnable on the live box
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Bring up / reconcile. Safe to re-run: converges to exactly these flags.
tailscale up \
    --ssh \
    --hostname=mc-temp \
    --advertise-tags=tag:vps-admin \
    --accept-dns=false \
    --auth-key="${TS_AUTHKEY_ADMIN}"

### Minecraft stack ###
# Only start once the world has been restored — a first start against an empty
# data/ would generate a brand-new world into it. After restoring, either
# re-run this script or just `docker compose up -d` here.
if [[ -d ./data && -n "$(ls -A ./data 2>/dev/null)" ]]; then
    docker compose up -d
else
    echo "mc-temp: ./data is empty — restore the world first, then run: docker compose up -d"
fi

# disable `sshd` — admin is Tailscale SSH only from here; LISH is break-glass
apt purge -y openssh-server
