#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="exodussail-update"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/exodussail"
ENV_FILE="${CONFIG_DIR}/exodussail.env"
TOKEN_FILE="${CONFIG_DIR}/github-token"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: sudo ./install-systemd.sh [--user USER] [--repo-dir DIR]

Installs:
  ${SYSTEMD_DIR}/${SERVICE_NAME}.service
  ${SYSTEMD_DIR}/${SERVICE_NAME}.timer
  ${ENV_FILE}

The GitHub token must be stored in:
  ${TOKEN_FILE}

The token file may contain either:
  - the raw token on one line
  - GITHUB_TOKEN=<token>
EOF
}

RUN_USER="${SUDO_USER:-}"
REPO_DIR="$SCRIPT_DIR"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            [[ $# -ge 2 ]] || die "--user requires a value"
            RUN_USER="$2"
            shift 2
            ;;
        --repo-dir)
            [[ $# -ge 2 ]] || die "--repo-dir requires a value"
            REPO_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -n "$RUN_USER" ]] || die "could not determine target user; pass --user"
id "$RUN_USER" >/dev/null 2>&1 || die "user does not exist: $RUN_USER"
[[ -d "$REPO_DIR" ]] || die "repo dir does not exist: $REPO_DIR"
[[ -x "${REPO_DIR}/update.sh" ]] || die "missing executable: ${REPO_DIR}/update.sh"

install -d -m 0755 "$CONFIG_DIR"

if [[ ! -e "$TOKEN_FILE" ]]; then
    install -m 0600 /dev/null "$TOKEN_FILE"
    cat <<EOF
Created ${TOKEN_FILE}
Add a GitHub token with gist write access before starting the service.
EOF
fi

chown root:"$RUN_USER" "$TOKEN_FILE"
chmod 0640 "$TOKEN_FILE"

if [[ ! -e "$ENV_FILE" ]]; then
    install -m 0644 /dev/null "$ENV_FILE"
cat > "$ENV_FILE" <<EOF
EXODUSSAIL_GITHUB_TOKEN_FILE=${TOKEN_FILE}
# EXODUSSAIL_GIST_ID_FILE=${REPO_DIR}/.gist_id
# EXODUSSAIL_FEED_URL=https://example.invalid/path/to/feed
# EXODUSSAIL_START=2025-11-01T00:00:00Z
EOF
fi

sed \
    -e "s|__RUN_USER__|${RUN_USER}|g" \
    -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${SCRIPT_DIR}/systemd/${SERVICE_NAME}.service" \
    > "${SYSTEMD_DIR}/${SERVICE_NAME}.service"

install -m 0644 \
    "${SCRIPT_DIR}/systemd/${SERVICE_NAME}.timer" \
    "${SYSTEMD_DIR}/${SERVICE_NAME}.timer"

chmod 0644 "${SYSTEMD_DIR}/${SERVICE_NAME}.service" "${SYSTEMD_DIR}/${SERVICE_NAME}.timer"

systemctl daemon-reload

if [[ -s "$TOKEN_FILE" ]]; then
    systemctl enable --now "${SERVICE_NAME}.timer"
    TIMER_ACTION="enabled and started"
else
    systemctl enable "${SERVICE_NAME}.timer"
    TIMER_ACTION="enabled but not started"
fi

cat <<EOF
Installed ${SERVICE_NAME}.service and ${SERVICE_NAME}.timer
The timer is ${TIMER_ACTION}.

Timer status:
  systemctl status ${SERVICE_NAME}.timer

Run once manually:
  systemctl start ${SERVICE_NAME}.service

Logs:
  journalctl -u ${SERVICE_NAME}.service -f
EOF
