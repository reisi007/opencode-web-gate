#!/usr/bin/env bash
# sync.sh: Login-Seite (apps/web/dist) via rclone auf den VPS spiegeln.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo ".env fehlt -> ./setup.sh"; exit 1; }
# shellcheck disable=SC1091
source .env

DIST="${LOCAL_DIST:-apps/web/dist}"
REMOTE_PATH="${RCLONE_REMOTE:-vps.example.com}:${RCLONE_PATH:-/code.example.com}"

echo "Sync $DIST -> $REMOTE_PATH ..."
rclone sync "$DIST" "$REMOTE_PATH" --transfers=20 --track-renames --progress
echo "Sync ok."
