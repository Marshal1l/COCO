#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

COCO_RPI_SERIAL_DEVICE="${COCO_RPI_SERIAL_DEVICE:-/dev/ttyUSB0}"
COCO_RPI_SERIAL_BAUD="${COCO_RPI_SERIAL_BAUD:-1500000}"
COCO_RPI_SERIAL_LOG_DIR="${COCO_RPI_SERIAL_LOG_DIR:-/home/mzh/coco-serial-logs}"
COCO_SERIAL_LOCAL_LOG_DIR="${COCO_SERIAL_LOCAL_LOG_DIR:-$COCO_ROOT_DIR/docs/log/serial}"
COCO_RPI_SUDO_PASSWORD="${COCO_RPI_SUDO_PASSWORD:-$COCO_RPI_PASSWORD}"

ACTION=""
DURATION=30
TAG="$(date +%Y%m%d-%H%M%S)"
FETCH_REMOTE_FILE=""
TAIL_LINES=120
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 <action> [options]

Capture RK3588 kernel/RMM logs from the Raspberry Pi serial adapter.

Actions:
  start              Start a persistent logger on the Pi.
  status             Show serial device and persistent logger status.
  fetch              Copy the latest persistent log back to docs/log/serial.
  capture            Capture a short live serial window to docs/log/serial.
  tail               Follow the latest persistent log on the Pi.
  stop               Stop the persistent logger on the Pi.

Options:
  --seconds N        Duration for capture. Default: $DURATION.
  --tag NAME         Log filename tag. Default: current timestamp.
  --remote-file P    Remote file to fetch instead of latest.log.
  --tail-lines N     Initial lines for tail. Default: $TAIL_LINES.
  --dry-run          Print commands without running them.
  -h, --help         Show this help.

Environment:
  COCO_RPI_HOST              Default: $COCO_RPI_HOST
  COCO_RPI_PASSWORD          Optional SSH password, e.g. root
  COCO_RPI_SUDO_PASSWORD     Defaults to COCO_RPI_PASSWORD
  COCO_RPI_SERIAL_DEVICE     Default: $COCO_RPI_SERIAL_DEVICE
  COCO_RPI_SERIAL_BAUD       Default: $COCO_RPI_SERIAL_BAUD
  COCO_RPI_SERIAL_LOG_DIR    Default: $COCO_RPI_SERIAL_LOG_DIR
  COCO_SERIAL_LOCAL_LOG_DIR  Default: $COCO_SERIAL_LOCAL_LOG_DIR

Recommended failure workflow:
  1. Start before a risky run:
       COCO_RPI_PASSWORD=root $0 start --tag imagecache-test
  2. Run the test.
  3. If it fails, fetch the serial log:
       COCO_RPI_PASSWORD=root $0 fetch
EOF
}

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi

ACTION="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds)
            [[ $# -ge 2 ]] || coco_die "--seconds requires a value"
            DURATION="$2"
            shift
            ;;
        --tag)
            [[ $# -ge 2 ]] || coco_die "--tag requires a value"
            TAG="$2"
            shift
            ;;
        --remote-file)
            [[ $# -ge 2 ]] || coco_die "--remote-file requires a value"
            FETCH_REMOTE_FILE="$2"
            shift
            ;;
        --tail-lines)
            [[ $# -ge 2 ]] || coco_die "--tail-lines requires a value"
            TAIL_LINES="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            coco_die "unknown option: $1"
            ;;
    esac
    shift
done

case "$ACTION" in
    start|status|fetch|capture|tail|stop)
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        coco_die "unknown action: $ACTION"
        ;;
esac

[[ "$DURATION" =~ ^[0-9]+$ ]] || coco_die "--seconds must be an integer"
[[ "$TAIL_LINES" =~ ^[0-9]+$ ]] || coco_die "--tail-lines must be an integer"

coco_require_cmd ssh scp
if [[ -n "$COCO_RPI_PASSWORD" ]]; then
    coco_require_cmd sshpass
fi

ssh_cmd=(
    ssh
    -T
    -p "$COCO_RPI_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
scp_cmd=(
    scp
    -P "$COCO_RPI_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
if [[ -n "$COCO_RPI_PASSWORD" ]]; then
    ssh_cmd=(sshpass -p "$COCO_RPI_PASSWORD" "${ssh_cmd[@]}")
    scp_cmd=(sshpass -p "$COCO_RPI_PASSWORD" "${scp_cmd[@]}")
fi

run_cmd() {
    printf '[coco-serial]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

run_pi() {
    local command="$1"
    run_cmd "${ssh_cmd[@]}" "$COCO_RPI_HOST" "$command"
}

sudo_remote_cmd() {
    local body="$1"

    if [[ -n "$COCO_RPI_SUDO_PASSWORD" ]]; then
        printf "printf '%%s\\n' %q | sudo -S -p '' bash -lc %q" \
            "$COCO_RPI_SUDO_PASSWORD" "$body"
    else
        printf "sudo bash -lc %q" "$body"
    fi
}

serial_common_header() {
    cat <<EOF
device=$(printf '%q' "$COCO_RPI_SERIAL_DEVICE")
baud=$(printf '%q' "$COCO_RPI_SERIAL_BAUD")
log_dir=$(printf '%q' "$COCO_RPI_SERIAL_LOG_DIR")
pid_file="\$log_dir/rk3588-serial.pid"
latest_link="\$log_dir/latest.log"
latest_path_file="\$log_dir/rk3588-serial.latest-path"
EOF
}

start_logger() {
    local tag_sanitized log_file body
    tag_sanitized="$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._=-' '_')"
    log_file="$COCO_RPI_SERIAL_LOG_DIR/rk3588-serial-$tag_sanitized.log"

    body="$(serial_common_header)
log_file=$(printf '%q' "$log_file")
set -euo pipefail
install -d -m 0755 \"\$log_dir\"
if [[ -s \"\$pid_file\" ]]; then
    old_pid=\"\$(cat \"\$pid_file\" || true)\"
    if [[ -n \"\$old_pid\" ]] && kill -0 \"\$old_pid\" 2>/dev/null; then
        echo \"serial logger already running: pid=\$old_pid log=\$(cat \"\$latest_path_file\" 2>/dev/null || readlink -f \"\$latest_link\" 2>/dev/null || true)\"
        exit 0
    fi
fi
touch \"\$log_file\"
chmod 0644 \"\$log_file\"
ln -sfn \"\$log_file\" \"\$latest_link\"
printf '%s\n' \"\$log_file\" > \"\$latest_path_file\"
COCO_SERIAL_DEVICE=\"\$device\" COCO_SERIAL_BAUD=\"\$baud\" COCO_SERIAL_LOG=\"\$log_file\" \
    nohup bash -lc '
        set -euo pipefail
        printf \"=== coco rk3588 serial start %s device=%s baud=%s ===\\n\" \"\$(date -Is)\" \"\$COCO_SERIAL_DEVICE\" \"\$COCO_SERIAL_BAUD\"
        stty -F \"\$COCO_SERIAL_DEVICE\" \"\$COCO_SERIAL_BAUD\" raw -echo -ixon -ixoff -crtscts
        exec cat \"\$COCO_SERIAL_DEVICE\"
    ' >> \"\$log_file\" 2>&1 &
logger_pid=\$!
printf '%s\n' \"\$logger_pid\" > \"\$pid_file\"
echo \"started serial logger: pid=\$logger_pid log=\$log_file\"
"
    run_pi "$(sudo_remote_cmd "$body")"
}

status_logger() {
    local body
    body="$(serial_common_header)
set -euo pipefail
echo \"host=\$(hostname)\"
if [[ -e \"\$device\" ]]; then
    ls -l \"\$device\"
else
    echo \"missing serial device: \$device\"
fi
if [[ -s \"\$pid_file\" ]]; then
    pid=\"\$(cat \"\$pid_file\" || true)\"
    if [[ -n \"\$pid\" ]] && kill -0 \"\$pid\" 2>/dev/null; then
        echo \"serial logger: running pid=\$pid\"
    else
        echo \"serial logger: stale pid=\$pid\"
    fi
else
    echo \"serial logger: not running\"
fi
if [[ -e \"\$latest_link\" ]]; then
    echo \"latest=\$(readlink -f \"\$latest_link\")\"
    ls -lh \"\$latest_link\" || true
fi
"
    run_pi "$(sudo_remote_cmd "$body")"
}

stop_logger() {
    local body
    body="$(serial_common_header)
set -euo pipefail
if [[ ! -s \"\$pid_file\" ]]; then
    echo \"serial logger is not running\"
    exit 0
fi
pid=\"\$(cat \"\$pid_file\" || true)\"
if [[ -z \"\$pid\" ]] || ! kill -0 \"\$pid\" 2>/dev/null; then
    rm -f \"\$pid_file\"
    echo \"removed stale serial logger pid file\"
    exit 0
fi
kill \"\$pid\" 2>/dev/null || true
for _ in \$(seq 1 20); do
    if ! kill -0 \"\$pid\" 2>/dev/null; then
        rm -f \"\$pid_file\"
        echo \"stopped serial logger: pid=\$pid\"
        exit 0
    fi
    sleep 0.2
done
kill -9 \"\$pid\" 2>/dev/null || true
rm -f \"\$pid_file\"
echo \"force-stopped serial logger: pid=\$pid\"
"
    run_pi "$(sudo_remote_cmd "$body")"
}

resolve_remote_log() {
    local body
    body="$(serial_common_header)
set -euo pipefail
if [[ -n $(printf '%q' "$FETCH_REMOTE_FILE") ]]; then
    printf '%s\n' $(printf '%q' "$FETCH_REMOTE_FILE")
elif [[ -e \"\$latest_link\" ]]; then
    readlink -f \"\$latest_link\"
else
    ls -1t \"\$log_dir\"/rk3588-serial-*.log 2>/dev/null | head -n 1
fi
"
    "${ssh_cmd[@]}" "$COCO_RPI_HOST" "$body"
}

fetch_log() {
    local remote_file dest

    coco_ensure_dir "$COCO_SERIAL_LOCAL_LOG_DIR"
    if [[ "$DRY_RUN" == "1" ]]; then
        remote_file="${FETCH_REMOTE_FILE:-$COCO_RPI_SERIAL_LOG_DIR/latest.log}"
    else
        remote_file="$(resolve_remote_log | tail -n 1)"
    fi
    [[ -n "$remote_file" ]] || coco_die "no remote serial log found on $COCO_RPI_HOST"
    dest="$COCO_SERIAL_LOCAL_LOG_DIR/$(basename "$remote_file")"
    run_cmd "${scp_cmd[@]}" "$COCO_RPI_HOST:$remote_file" "$dest"
    coco_log "fetched serial log: $dest"
}

capture_live() {
    local local_file body

    coco_ensure_dir "$COCO_SERIAL_LOCAL_LOG_DIR"
    local_file="$COCO_SERIAL_LOCAL_LOG_DIR/rk3588-serial-capture-$TAG.log"
    body="$(serial_common_header)
set -euo pipefail
stty -F \"\$device\" \"\$baud\" raw -echo -ixon -ixoff -crtscts
echo \"=== coco rk3588 serial live capture \$(date -Is) device=\$device baud=\$baud seconds=$DURATION ===\"
timeout --foreground $DURATION cat \"\$device\" || rc=\$?
if [[ \${rc:-0} -ne 124 && \${rc:-0} -ne 0 ]]; then
    exit \"\$rc\"
fi
"
    printf '[coco-serial] writing %s\n' "$local_file"
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '[coco-serial]'
        printf ' %q' "${ssh_cmd[@]}" "$COCO_RPI_HOST" "$(sudo_remote_cmd "$body")"
        printf ' | tee %q\n' "$local_file"
    else
        "${ssh_cmd[@]}" "$COCO_RPI_HOST" "$(sudo_remote_cmd "$body")" | tee "$local_file"
    fi
}

tail_log() {
    local body
    body="$(serial_common_header)
set -euo pipefail
if [[ -e \"\$latest_link\" ]]; then
    tail -n $TAIL_LINES -f \"\$latest_link\"
else
    echo \"no latest serial log found: \$latest_link\" >&2
    exit 1
fi
"
    run_pi "$(sudo_remote_cmd "$body")"
}

case "$ACTION" in
    start)
        start_logger
        ;;
    status)
        status_logger
        ;;
    fetch)
        fetch_log
        ;;
    capture)
        capture_live
        ;;
    tail)
        tail_log
        ;;
    stop)
        stop_logger
        ;;
esac
