#!/usr/bin/env bash
# One-command maintenance for the relay VPS.
#
#   From your laptop (repo checkout):   ./update.sh [--no-reboot]
#   Re-attach to a running/last run:    ./update.sh --follow
#   (Run on the box itself, the same commands work in /root/vps-relay.)
#
# What a run does, on the box, as root:
#   1. apt full-upgrade: Debian, Docker engine, host Tailscale; autoremove
#   2. git pull --ff-only, then docker compose pull + up -d (pinned image bumps)
#   3. prune dangling images
#   4. reboot if a newer kernel / reboot-required is pending (unless --no-reboot)
#
# Why it's shaped like this: admin access is Tailscale SSH, served by the very
# tailscaled that apt may upgrade. Restarting tailscaled drops every SSH session
# and can kill whatever runs inside it -- including a half-finished dpkg. So the
# real work runs in a transient systemd unit (its own cgroup, unaffected by the
# session dying) that writes to $LOG; the SSH session only follows that log.
# From the laptop, a dropped connection is retried until the run -- and any
# reboot it triggers -- has finished.
set -euo pipefail

UNIT=vps-relay-update
LOG=/var/log/vps-relay-update.log
HOST=${VPS_HOST:-root@vps-relay}
REMOTE_SCRIPT=/root/vps-relay/update.sh

usage() {
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

### Laptop side: ssh in, and keep reconnecting across tailscaled restarts/reboots ###
client() {
    local opts=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
    ssh "${opts[@]}" "$HOST" true || { echo "cannot reach $HOST" >&2; exit 1; }
    if [[ -t 0 ]]; then opts+=(-t); fi

    local rc=0 tries=0
    ssh "${opts[@]}" "$HOST" "$REMOTE_SCRIPT" "$@" || rc=$?
    # 255 = connection dropped (tailscaled restarted, or box rebooting)
    #   3 = run finished and the box is about to reboot
    while [[ $rc -eq 255 || $rc -eq 3 ]]; do
        tries=$((tries + 1))
        if [[ $tries -gt 60 ]]; then
            echo "giving up after $tries reconnects; check later with ./update.sh --follow" >&2
            exit 1
        fi
        echo "--- disconnected (tailscaled restart or reboot); reconnecting in 10s ---"
        sleep 10
        rc=0
        ssh "${opts[@]}" "$HOST" "$REMOTE_SCRIPT" --follow || rc=$?
    done
    exit "$rc"
}

### Box side ###
log() { echo "==> [$(date '+%F %T')] $*"; }

reboot_needed() {
    [[ -e /run/reboot-required ]] && return 0
    local newest
    newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -n1)
    [[ -n $newest && $newest != "$(uname -r)" ]]
}

summary() {
    echo "kernel:    $(uname -r)  (up since $(uptime -s))"
    echo "tailscale: $(tailscale version | head -n1)"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
}

# Exit codes: 0 ok, 1 failed/unknown, 3 reboot pending (laptop keeps waiting).
verdict() {
    local result
    result=$(grep '^==> RESULT: ' "$LOG" | tail -n1 || true)
    case $result in
        *"RESULT: ok"*)
            summary
            ;;
        *"RESULT: reboot"*)
            if [[ $(stat -c %Y "$LOG") -ge $(date -d "$(uptime -s)" +%s) ]]; then
                echo "rebooting -- not back up yet"
                return 3
            fi
            echo "rebooted."
            summary
            ;;
        *"RESULT: failed"*)
            echo "update FAILED -- full log: $LOG (previous run: $LOG.prev)" >&2
            return 1
            ;;
        *)
            echo "run ended without a result -- see: journalctl -u $UNIT" >&2
            return 1
            ;;
    esac
}

follow() {
    if systemctl is-active --quiet "$UNIT"; then
        tail -n 20 -F "$LOG" 2>/dev/null &
        local tail_pid=$!
        while systemctl is-active --quiet "$UNIT"; do sleep 2; done
        sleep 1
        kill "$tail_pid" 2>/dev/null || true
    elif [[ -f $LOG ]]; then
        tail -n 20 "$LOG"
    else
        echo "no update log at $LOG" >&2
        return 1
    fi
    verdict
}

start() {
    if systemctl is-active --quiet "$UNIT"; then
        echo "an update is already running -- following it"
        follow
        return
    fi
    if [[ -f $LOG ]]; then mv -f "$LOG" "$LOG.prev"; fi
    systemd-run --unit="$UNIT" --collect --quiet \
        --setenv=HOME=/root \
        -p StandardOutput="append:$LOG" -p StandardError="append:$LOG" \
        "$SELF" --run "$@"
    echo "started $UNIT -- it keeps running if this session drops (Ctrl-C only detaches)"
    follow
}

run() {
    local reboot=1 arg
    for arg in "$@"; do
        if [[ $arg == --no-reboot ]]; then reboot=0; fi
    done
    trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "==> RESULT: failed (exit $rc)"; fi; exit $rc' EXIT

    export DEBIAN_FRONTEND=noninteractive
    local apt=(apt-get -y -o DPkg::Lock::Timeout=600
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

    log "apt update"
    "${apt[@]}" update
    log "apt full-upgrade (Debian, Docker engine, host Tailscale -- SSH may drop here)"
    "${apt[@]}" full-upgrade
    log "apt autoremove"
    "${apt[@]}" autoremove --purge
    "${apt[@]}" autoclean

    log "git pull"
    if ! git -C "$DIR" pull --ff-only; then
        log "WARNING: git pull failed -- continuing with the current checkout"
    fi

    log "docker compose pull + up"
    (cd "$DIR" && docker compose pull && docker compose up -d)
    log "prune dangling images"
    docker image prune -f

    if reboot_needed; then
        if [[ $reboot -eq 1 ]]; then
            log "reboot required (running $(uname -r)) -- rebooting in 5s"
            echo "==> RESULT: reboot"
            sleep 5
            systemctl reboot
            exit 0
        fi
        log "NOTE: reboot required but --no-reboot given; run 'systemctl reboot' when convenient"
    fi
    log "done"
    echo "==> RESULT: ok"
}

### Dispatch ###
case ${1:-} in -h | --help) usage; exit 0 ;; esac

if [[ $(hostname) != vps-relay ]]; then
    client "$@"
fi

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
SELF=$(readlink -f "$0")
DIR=$(dirname "$SELF")

case ${1:-} in
    --run) shift; run "$@" ;;
    --follow | -f) follow ;;
    "" | --no-reboot) start "$@" ;;
    *) usage >&2; exit 2 ;;
esac
