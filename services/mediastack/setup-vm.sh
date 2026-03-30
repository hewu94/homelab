#!/usr/bin/env bash
set -euo pipefail

# ── Mediastack VM 110 Setup Script ─────────────────────
# Prepares the host for the mediastack docker-compose deployment.
# Run as root on VM 110 (192.168.1.110).
# Prerequisites: Docker + Docker Compose already installed.

PUID=1000
PGID=1000
NFS_SERVER="192.168.1.198"
NFS_EXPORT="/export/media"
NFS_MOUNT="/media"
CONFIG_DIR="/opt/mediastack"

echo "=== 1/5 Install NFS client ==="
apt-get update -qq
apt-get install -y nfs-common

echo "=== 2/5 Mount NFS share from OMV ==="
mkdir -p "$NFS_MOUNT"

if mountpoint -q "$NFS_MOUNT"; then
    echo "  $NFS_MOUNT is already mounted, skipping."
else
    mount -t nfs4 "${NFS_SERVER}:${NFS_EXPORT}" "$NFS_MOUNT"
    echo "  Mounted ${NFS_SERVER}:${NFS_EXPORT} → $NFS_MOUNT"
fi

# Add to fstab if not already there
if ! grep -q "$NFS_EXPORT" /etc/fstab; then
    echo "${NFS_SERVER}:${NFS_EXPORT}  ${NFS_MOUNT}  nfs4  rw,hard,intr  0  0" >> /etc/fstab
    echo "  Added fstab entry."
else
    echo "  fstab entry already exists, skipping."
fi

echo "=== 3/5 Create media directory structure on NFS ==="
mkdir -p "$NFS_MOUNT"/{movies,tv,downloads/{complete,incomplete}}
chown -R "${PUID}:${PGID}" "$NFS_MOUNT"/{movies,tv,downloads}
echo "  Created: movies/, tv/, downloads/{complete,incomplete}"

echo "=== 4/5 Create config directories ==="
mkdir -p "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"/{plex,sonarr,radarr,prowlarr,sabnzbd,bazarr,overseerr,gluetun}
chown -R "${PUID}:${PGID}" "$CONFIG_DIR"
echo "  Created config dirs under $CONFIG_DIR"

echo "=== 5/5 Verify ==="
echo ""
echo "NFS mount:"
df -h "$NFS_MOUNT"
echo ""
echo "NFS read/write test:"
TESTFILE="${NFS_MOUNT}/downloads/.writetest"
touch "$TESTFILE" && rm "$TESTFILE" && echo "  OK — read/write works" || echo "  FAILED — check NFS permissions"
echo ""
echo "Directory layout:"
echo "  $CONFIG_DIR/        (app configs, local SSD)"
ls -1 "$CONFIG_DIR" | sed 's/^/    /'
echo "  $NFS_MOUNT/         (media, NFS from OMV)"
ls -1 "$NFS_MOUNT" | sed 's/^/    /'
echo ""
echo "=== Done ==="
echo "Next steps:"
echo "  1. Copy docker-compose.yml and .env to $CONFIG_DIR/"
echo "  2. Fill in VPN credentials and PLEX_CLAIM in .env"
echo "  3. cd $CONFIG_DIR && docker compose up -d"
