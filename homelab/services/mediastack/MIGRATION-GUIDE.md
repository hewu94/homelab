# Mediastack Migration Guide

> Migrate Plex (CT 203), SABnzbd (CT 206), and media files to the new
> Docker-based mediastack on VM 110, keeping your existing Plex library intact.

---

## Overview

| What | From | To |
|------|------|----|
| Plex | CT 203 (192.168.1.203) | Docker on VM 110 |
| SABnzbd | CT 206 (192.168.1.206) | Docker on VM 110 (via Gluetun VPN) |
| Media files | OMV /data/media (flat) | OMV /data/media reorganised into TRaSH layout |
| Config | — | /opt/mediastack on VM 110 local disk |

---

## Phase 0 — Survey Current State

Before touching anything, document what you have.

### 0.1 Check current OMV media layout

```bash
ssh manager@192.168.1.198
ls -1 /data/media/          # or wherever your files live
du -sh /data/media/*/
```

Write down the top-level folders. Typical legacy layouts:
- Everything in one flat folder
- `Movies/`, `TV Shows/`, `Downloads/`, plus misc folders
- Random naming (`filme/`, `serien/`, etc.)

### 0.2 Check current Plex library paths

```bash
# On CT 203
cat /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
```

Also check via Plex Web UI → **Settings → Manage → Libraries** and note each library's folder path(s). You'll need to map these to the new paths later.

### 0.3 Note Plex server identity

```bash
# On CT 203 — save these values
grep -oP 'MachineIdentifier="[^"]*"' \
  /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
```

Your Plex clients, watched history, and plex.tv link depend on this identifier. It's preserved automatically when you copy the database.

---

## Phase 1 — Reorganise Media Files on OMV

The new stack expects the TRaSH-guides directory layout so that Sonarr/Radarr
can hardlink files from `downloads/` to `media/` (same filesystem = instant, no
extra disk usage).

### Target layout on OMV

```
/export/mediastack/         ← NFS export (backed by /data/media or bind mount)
├── media/
│   ├── movies/             ← Radarr library (Plex "Movies" library)
│   └── tv/                 ← Sonarr library (Plex "TV Shows" library)
└── downloads/
    ├── complete/           ← SABnzbd completed downloads
    └── incomplete/         ← SABnzbd in-progress
```

### 1.1 Create the new directory structure on OMV

```bash
ssh manager@192.168.1.198

# Adjust the base path if your NFS export points elsewhere
MEDIASTACK="/export/mediastack"  # or the underlying dataset path

sudo mkdir -p "$MEDIASTACK"/media/{movies,tv}
sudo mkdir -p "$MEDIASTACK"/downloads/{complete,incomplete}
```

### 1.2 Move existing movies

**Identify** your current movie folder(s). Common names: `Movies/`, `Filme/`, `movies/`.

```bash
# Dry run first — just list what would move
ls /data/media/Movies/ | head -20

# Move (on the OMV server so it's a local rename, not a network copy)
# If source and destination are on the same ZFS dataset, mv is instant.
sudo mv /data/media/Movies/* "$MEDIASTACK"/media/movies/
```

> **Important:** If your movies are scattered across multiple folders, move
> them all into `media/movies/`. Radarr expects one root folder.

### 1.3 Move existing TV shows

```bash
# Same approach — identify and move
sudo mv /data/media/TV\ Shows/* "$MEDIASTACK"/media/tv/

# Or if named differently:
# sudo mv /data/media/Serien/* "$MEDIASTACK"/media/tv/
```

### 1.4 Move existing downloads (optional)

If SABnzbd's completed downloads are on OMV:

```bash
sudo mv /data/media/Downloads/complete/* "$MEDIASTACK"/downloads/complete/
sudo mv /data/media/Downloads/incomplete/* "$MEDIASTACK"/downloads/incomplete/
```

### 1.5 Fix ownership

```bash
sudo chown -R 1000:1000 "$MEDIASTACK"/{media,downloads}
```

### 1.6 Verify

```bash
echo "Movies: $(ls "$MEDIASTACK"/media/movies/ | wc -l) items"
echo "TV:     $(ls "$MEDIASTACK"/media/tv/ | wc -l) items"
du -sh "$MEDIASTACK"/media/*
```

---

## Phase 2 — Migrate Plex Library (Keep Watch History & Metadata)

This copies Plex's database, metadata, and thumbnails so you keep:
- All watched/unwatched status
- Custom posters and collections
- "On Deck" and "Continue Watching"
- Match history (no re-matching needed)

### 2.1 Stop Plex on CT 203

```bash
ssh root@192.168.1.203
systemctl stop plexmediaserver
```

### 2.2 Locate the Plex data directory

Standard paths depending on installation:

| Install type | Path |
|---|---|
| Package (apt) | `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/` |
| Snap | `/snap/plexmediaserver/common/Library/Application Support/Plex Media Server/` |
| Docker (linuxserver) | `<config_volume>/Library/Application Support/Plex Media Server/` |

```bash
PLEX_DATA="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
du -sh "$PLEX_DATA"
```

### 2.3 Copy Plex data to VM 110

```bash
# From CT 203 → VM 110
# This can be large (10-50+ GB depending on metadata/thumbnails)
rsync -avhP --info=progress2 \
  "$PLEX_DATA/" \
  root@192.168.1.110:/opt/mediastack/plex/Library/Application\ Support/Plex\ Media\ Server/
```

> **Alternative:** If CT 203 can't reach VM 110 directly, use OMV as a
> staging area, or run rsync from VM 110 pulling from CT 203.

### 2.4 Fix ownership on VM 110

```bash
ssh root@192.168.1.110
chown -R 1000:1000 /opt/mediastack/plex/
```

### 2.5 Update Plex library paths

Plex stores library folder paths in its database. You need to update them to
match the new container paths.

The docker-compose maps: `${MEDIA_DIR}/media:/data/media`
So inside the Plex container, your media is at `/data/media/movies/` and `/data/media/tv/`.

**Option A: Edit via Plex Web UI (recommended)**

1. Start Plex: `docker compose up -d plex`
2. Open Plex Web UI (http://192.168.1.110:32400/web)
3. Go to **Settings → Manage → Libraries**
4. For each library, click **Edit → Folders** and update the path:
   - Movies: `/data/media/movies`
   - TV Shows: `/data/media/tv`
5. Click **Scan Library Files**

**Option B: Edit the database directly (advanced)**

Only do this if paths are deeply embedded or you have many libraries.

```bash
# On VM 110, before starting Plex
cd /opt/mediastack/plex/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/

# Backup first!
cp com.plexapp.plugins.library.db com.plexapp.plugins.library.db.bak

# Check current paths
sqlite3 com.plexapp.plugins.library.db \
  "SELECT id, name, root_path FROM section_locations;"

# Example: old path was /mnt/media/Movies → new is /data/media/movies
sqlite3 com.plexapp.plugins.library.db \
  "UPDATE section_locations SET root_path = REPLACE(root_path, '/OLD/PATH/Movies', '/data/media/movies');"

sqlite3 com.plexapp.plugins.library.db \
  "UPDATE section_locations SET root_path = REPLACE(root_path, '/OLD/PATH/TV Shows', '/data/media/tv');"

# Verify
sqlite3 com.plexapp.plugins.library.db \
  "SELECT id, name, root_path FROM section_locations;"
```

### 2.6 Claim the Plex server

Since the MachineIdentifier is preserved, your server should appear in your
plex.tv account automatically. If it doesn't (or for Docker first-run), get a
fresh claim token:

1. Go to https://plex.tv/claim (valid for 4 minutes)
2. Set `PLEX_CLAIM=claim-xxxx` in your `.env`
3. Start Plex

---

## Phase 3 — Migrate SABnzbd Config

### 3.1 Export SABnzbd config from CT 206

```bash
ssh root@192.168.1.206

# Locate SABnzbd config
find / -name "sabnzbd.ini" 2>/dev/null

# Copy to VM 110
scp /path/to/sabnzbd.ini root@192.168.1.110:/opt/mediastack/sabnzbd/sabnzbd.ini
```

### 3.2 Update paths in sabnzbd.ini

```bash
ssh root@192.168.1.110

# Edit /opt/mediastack/sabnzbd/sabnzbd.ini and update:
# complete_dir   = /data/downloads/complete
# incomplete_dir = /data/downloads/incomplete
sed -i 's|complete_dir = .*|complete_dir = /data/downloads/complete|' /opt/mediastack/sabnzbd/sabnzbd.ini
sed -i 's|incomplete_dir = .*|incomplete_dir = /data/downloads/incomplete|' /opt/mediastack/sabnzbd/sabnzbd.ini
```

### 3.3 Fix ownership

```bash
chown -R 1000:1000 /opt/mediastack/sabnzbd/
```

---

## Phase 4 — Start the Stack

### 4.1 Prepare .env

```bash
ssh root@192.168.1.110
cd /opt/mediastack

# Copy and edit the env file
cp .env.example .env
nano .env
```

Fill in:
- `PLEX_CLAIM` — from https://plex.tv/claim
- `VPN_USERNAME` / `VPN_PASSWORD` — NordVPN **service credentials** (not regular login)
- Verify `MEDIA_DIR=/mnt/mediastack`

### 4.2 Start everything

```bash
cd /opt/mediastack
docker compose up -d
```

### 4.3 Verify containers

```bash
docker compose ps
# All should show "Up" / "healthy"
```

---

## Phase 5 — Configure ARR Apps

### 5.1 Sonarr (http://192.168.1.110:8989)

1. **Media Management → Root Folders** → Add: `/data/media/tv`
2. **Download Clients** → Add SABnzbd:
   - Host: `gluetun` (container name, since SABnzbd uses gluetun's network)
   - Port: `8080`
3. **Import Existing** → Click "Library Import" if you want Sonarr to manage existing TV shows

### 5.2 Radarr (http://192.168.1.110:7878)

1. **Media Management → Root Folders** → Add: `/data/media/movies`
2. **Download Clients** → Add SABnzbd (same as Sonarr)
3. **Import Existing** → Click "Library Import" for existing movies

### 5.3 Prowlarr (http://192.168.1.110:9696)

1. Add your indexers
2. **Settings → Apps** → Add Sonarr + Radarr with their API keys

### 5.4 Overseerr (http://192.168.1.110:5055)

1. Connect to Plex (sign in with your Plex account)
2. Add Sonarr + Radarr connections

### 5.5 Bazarr (http://192.168.1.110:6767)

1. Connect to Sonarr + Radarr
2. Configure subtitle providers

---

## Phase 6 — Verify Plex Library

### 6.1 Check library paths

In Plex Web UI → Settings → Manage → Libraries:
- Movies → should point to `/data/media/movies`
- TV Shows → should point to `/data/media/tv`

### 6.2 Scan and verify

1. Click **Scan Library Files** for each library
2. Verify movie/show count matches your expectations
3. Check a few items for:
   - Watched status preserved ✓
   - Custom posters preserved ✓
   - Collections preserved ✓

### 6.3 Test playback

Play a movie and a TV episode to confirm NFS streaming works.

---

## Phase 7 — Update Reverse Proxy (NPM)

Update Nginx Proxy Manager routes:

| Domain | New Backend |
|--------|------------|
| plex.wueblu.com | 192.168.1.110:32400 |
| sab.wueblu.com | 192.168.1.110:8080 |

---

## Phase 8 — Decommission Old Containers

**Wait at least 2 weeks** to catch any issues before removing the old CTs.

```bash
# On Proxmox
# Stop (don't destroy yet)
pct stop 203    # old plex
pct stop 206    # old sabnzbd
pct stop 201    # old data

# After 2 weeks of stable operation:
pct destroy 203
pct destroy 206
pct destroy 201
```

---

## Path Reference

| Context | Movies | TV Shows | Downloads |
|---------|--------|----------|-----------|
| OMV server | /export/mediastack/media/movies | /export/mediastack/media/tv | /export/mediastack/downloads/ |
| VM 110 host | /mnt/mediastack/media/movies | /mnt/mediastack/media/tv | /mnt/mediastack/downloads/ |
| Plex container | /data/media/movies | /data/media/tv | — |
| Sonarr/Radarr container | /data/media/tv | /data/media/movies | /data/downloads/ |
| SABnzbd container | — | — | /data/downloads/{complete,incomplete} |

> All containers sharing `/data` see the same filesystem, enabling **hardlinks**
> from downloads → media (instant, no extra disk usage).

---

## Troubleshooting

### Plex says "Library is empty" after migration
- Paths don't match. Check `section_locations` in the Plex DB vs actual container paths.
- Run `docker exec plex ls /data/media/movies/ | head` to verify files are visible inside the container.

### Hardlinks don't work (Sonarr/Radarr copies instead of linking)
- Downloads and media must be on the **same mount**. Both `/data/media/` and `/data/downloads/` must resolve to the same NFS filesystem.
- Check: `docker exec sonarr stat -f /data/media /data/downloads` — the filesystem ID should match.

### NFS permission denied
- Ensure OMV export uses `all_squash` mapped to uid/gid 1000.
- Check: `id` on the OMV server for the mapped user.

### Plex can't reach plex.tv / remote access broken
- Plex uses `network_mode: host` so it binds directly to VM 110's IP.
- Check firewall: port 32400 must be open on VM 110.
- Check NAT/port forward on your router for remote access.
