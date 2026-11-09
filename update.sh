#!/usr/bin/env bash
# One-command maintenance for the relay VPS.
#
#   From your laptop (repo checkout):   ./update.sh [--no-reboot]
#   Re-attach to a running/last run:    ./update.sh --follow   (alias --attach)
#   One-shot result + health check:     ./update.sh --status
#   (Run on the box itself, the same commands work in /root/vps-relay.)
#
# What a run does, on the box, as root:
#   1. apt full-upgrade: Debian, Docker engine, host Tailscale; autoremove
#   2. git pull --ff-only, then docker compose pull + up -d (pinned image bumps)
#   3. prune images no container uses (old pinned versions)
#   4. reboot if a newer kernel / reboot-required is pending (unless --no-reboot)
#
# Why it's shaped like this: admin access is Tailscale SSH, served by the very
# tailscaled that apt may upgrade. Restarting tailscaled drops every SSH session
# and can kill whatever runs inside it -- including a half-finished dpkg. So the
# real work runs in a transient systemd unit (its own cgroup, unaffected by the
# session dying) that writes to $LOG; the SSH session only streams that log.
#
# The laptop side never trusts how a streaming session ended (a session killed
# by tailscaled restarting or the box shutting down exits with an arbitrary
# code). After every stream it asks the box for --status, retrying through
# drops and reboots until the box reports the run finished AND healthy.
set -euo pipefail

UNIT=vps-relay-update
LOG=/var/log/vps-relay-update.log
HOST=${VPS_HOST:-root@vps-relay}
REMOTE_SCRIPT=/root/vps-relay/update.sh
WAIT_LIMIT=900 # seconds the laptop waits for the box to come back healthy

# --status exit codes (box side)
ST_OK=0 ST_FAILED=1 ST_RUNNING=3 ST_NOT_READY=4

usage() {
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

### Laptop side ###
client() {
    local opts=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
    local stream_opts=("${opts[@]}")
    if [[ -t 0 ]]; then stream_opts+=(-t); fi
    local stream=() rc

    case ${1:-} in
        "" | --no-reboot)
            # Refresh the box's checkout first so this run uses the current script.
            if ! ssh "${opts[@]}" "$HOST" "git -C ${REMOTE_SCRIPT%/*} pull --ff-only -q"; then
                echo "cannot reach $HOST (or git pull failed there)" >&2
                exit 1
            fi
            stream=(--start-stream "$@")
            ;;
        --follow | --attach | -f) stream=(--stream) ;;
        --status) ;;
        *) usage >&2; exit 2 ;;
    esac

    local waited_since=$SECONDS
    while :; do
        if [[ ${#stream[@]} -gt 0 ]]; then
            rc=0
            ssh "${stream_opts[@]}" "$HOST" "$REMOTE_SCRIPT" "${stream[@]}" || rc=$?
            if [[ $rc -eq 130 ]]; then
                echo "detached -- the update keeps running; re-attach with: ./update.sh --follow"
                exit 0
            fi
            stream=()
        fi

        rc=0
        ssh "${opts[@]}" -o BatchMode=yes "$HOST" "$REMOTE_SCRIPT" --status 2>/dev/null || rc=$?
        case $rc in
            "$ST_OK" | "$ST_FAILED" | 2) exit "$rc" ;;
            "$ST_RUNNING") stream=(--stream); waited_since=$SECONDS; continue ;;
            "$ST_NOT_READY") ;;
            255) echo "--- $HOST unreachable (tailscaled restart or reboot) ---" ;;
            *) echo "--- unexpected status $rc from $HOST ---" ;;
        esac
        if [[ $((SECONDS - waited_since)) -ge $WAIT_LIMIT ]]; then
            echo "gave up after ${WAIT_LIMIT}s -- check later with: ./update.sh --status" >&2
            exit 1
        fi
        sleep 10
    done
}

### Box side ###
log() { echo "==> [$(date '+%F %T')] $*"; }

reboot_needed() {
    [[ -e /run/reboot-required ]] && return 0
    local newest
    newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -n1)
    [[ -n $newest && $newest != "$(uname -r)" ]]
}

# Prints problems; returns non-zero if the relay isn't fully up.
health() {
    local bad=0 c state
    state=$(systemctl is-system-running 2>/dev/null || true)
    case $state in
        running) ;;
        degraded) echo "system degraded -- failed units: $(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)" ;;
        *) echo "system state: $state"; bad=1 ;;
    esac
    for c in traefik tailscale-relay; do
        if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) != true ]]; then
            echo "container $c not running"
            bad=1
        fi
    done
    if ! docker exec tailscale-relay tailscale status --peers=false >/dev/null 2>&1; then
        echo "relay Tailscale (vps-relay-data) not connected"
        bad=1
    fi
    return "$bad"
}

summary() {
    echo "kernel:    $(uname -r)  (up since $(uptime -s))"
    echo "tailscale: $(tailscale version | head -n1)"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
}

# Exit codes: ST_OK, ST_FAILED, ST_RUNNING, ST_NOT_READY (rebooting / coming up).
status() {
    if systemctl is-active --quiet "$UNIT"; then
        echo "update still running"
        return "$ST_RUNNING"
    fi
    if [[ ! -f $LOG ]]; then
        echo "no update log at $LOG"
        return "$ST_FAILED"
    fi

    local result problems
    result=$(grep '^==> RESULT: ' "$LOG" | tail -n1 || true)
    case $result in
        *"RESULT: ok"*) ;;
        *"RESULT: reboot"*)
            if [[ $(stat -c %Y "$LOG") -ge $(date -d "$(uptime -s)" +%s) ]]; then
                echo "--- rebooting ---"
                return "$ST_NOT_READY"
            fi
            ;;
        *"RESULT: failed"*)
            echo "update FAILED -- full log: $LOG (previous run: $LOG.prev)"
            return "$ST_FAILED"
            ;;
        *)
            echo "run ended without a result -- see: journalctl -u $UNIT"
            return "$ST_FAILED"
            ;;
    esac

    if ! problems=$(health); then
        if [[ $(cut -d. -f1 /proc/uptime) -lt 300 ]]; then
            echo "--- up $(cut -d. -f1 /proc/uptime)s, still coming up: $(echo "$problems" | paste -sd ';' -) ---"
            return "$ST_NOT_READY"
        fi
        echo "UNHEALTHY after update:"
        echo "$problems"
        summary
        return "$ST_FAILED"
    fi
    [[ $result == *reboot* ]] && echo "rebooted."
    [[ -n $problems ]] && echo "WARNING: $problems"
    echo "update OK, relay healthy."
    summary
    return "$ST_OK"
}

# Stream the log until the run ends. Ctrl-C exits 130 (= detach).
stream() {
    trap 'exit 130' INT
    if systemctl is-active --quiet "$UNIT"; then
        tail -n 20 -F --pid=$$ "$LOG" 2>/dev/null &
        local tail_pid=$!
        trap 'kill "$tail_pid" 2>/dev/null; exit 130' INT
        while systemctl is-active --quiet "$UNIT"; do sleep 2; done
        sleep 1
        kill "$tail_pid" 2>/dev/null || true
    elif [[ -f $LOG ]]; then
        tail -n 20 "$LOG"
    fi
}

start() {
    if systemctl is-active --quiet "$UNIT"; then
        echo "an update is already running -- following it"
    else
        if [[ -f $LOG ]]; then mv -f "$LOG" "$LOG.prev"; fi
        systemd-run --unit="$UNIT" --collect --quiet \
            --setenv=HOME=/root \
            -p StandardOutput="append:$LOG" -p StandardError="append:$LOG" \
            "$SELF" --run "$@"
        echo "started $UNIT -- it keeps running if this session drops (Ctrl-C only detaches)"
    fi
    stream
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
    log "prune images not used by a container (old pinned versions)"
    docker image prune -af

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

reject() { echo "unexpected arguments: $*" >&2; usage >&2; exit 2; }

# Strict args: wrappers (e.g. Ghostty's ssh integration) have been seen appending
# their own words to the remote command, which must never start a run.
cmd=${1:-}
if [[ $# -gt 0 ]]; then shift; fi
case $cmd in
    --run | --start-stream | "" | --no-reboot)
        for arg in "$@"; do [[ $arg == --no-reboot ]] || reject "$cmd" "$@"; done ;;
    *) [[ $# -eq 0 ]] || reject "$cmd" "$@" ;;
esac
case $cmd in
    --run) run "$@" ;;
    --start-stream) start "$@" ;; # laptop-side helpers
    --stream) stream ;;
    --status) status ;;
    --follow | --attach | -f) stream; status ;;
    "") start; status ;;
    --no-reboot) start --no-reboot; status ;;
    *) reject "$cmd" ;;
esac
