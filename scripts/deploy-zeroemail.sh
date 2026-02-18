#!/bin/bash
# ============================================================
# Deploy ZeroEmail frontend to OVH VPS
# Called by GitHub Actions self-hosted runner.
#
# Usage: sudo deploy-zeroemail.sh <workspace-dir>
#
# Installs to: /srv/zeroemail
# Runs as: zeroemail (systemd unit)
# ============================================================
set -euo pipefail

SRC="${1:?Usage: $0 <workspace-dir>}"
TARGET="/srv/zeroemail"
SERVICE="zeroemail"

echo "[$(date)] Starting ZeroEmail frontend deploy..."

# Sync built app (exclude env files and git)
rsync -a --delete \
  --exclude='.env' \
  --exclude='.git' \
  --exclude='node_modules' \
  "$SRC/apps/mail/" "$TARGET/apps/mail/"

# Copy shared packages needed at runtime
rsync -a "$SRC/packages/" "$TARGET/packages/"
rsync -a "$SRC/package.json" "$TARGET/package.json"
rsync -a "$SRC/pnpm-lock.yaml" "$TARGET/pnpm-lock.yaml"
rsync -a "$SRC/pnpm-workspace.yaml" "$TARGET/pnpm-workspace.yaml"

# Fix ownership
chown -R zeroemail:zeroemail "$TARGET/"

# Restart service
systemctl restart "$SERVICE"

# Wait for health check
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  echo "[$(date)] Deploy OK — $SERVICE is running"
else
  echo "[$(date)] ERROR — $SERVICE failed to start!"
  journalctl -u "$SERVICE" --no-pager -n 20
  exit 1
fi
