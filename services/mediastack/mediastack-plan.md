# Mediastack VM — Migration & Setup Plan

## Goal

Consolidate media services (Plex, SABnzbd, data) from separate LXC containers into a single Docker-based VM (110 — mediastack) using the ARR suite, with all media data stored on SERVER-OMV via NFS.

## Current State

| Component | Current | Target |
|-----------|---------|--------|
| Plex | CT 203 (192.168.1.203, 64G disk) | Docker on VM 110 |
| SABnzbd | CT 206 (192.168.1.206, 8G disk) | Docker on VM 110 |
| Data | CT 201 (192.168.1.201, 8G disk) | Docker on VM 110 |
| ARR Suite | Not deployed | Docker on VM 110 |
| Media storage | OMV /data/media (26T) | NFS mount on VM 110 |

**VM 110 specs:** 4 GiB RAM, 32G disk, IP 192.168.1.110

## Architecture

```
                         ┌─────────────────────────────────────┐
                         │  VM 110 — mediastack (Docker)       │
                         │  192.168.1.110                      │
                         │                                     │
  Requests ──►  Overseerr ──► Sonarr ──► Prowlarr ──► Indexers │
                    │         Radarr ──►                       │
                    │            │                              │
                    │            ▼                              │
                    │        SABnzbd ──► /media/downloads       │
                    │            │                              │
                    │            ▼                              │
                    │     /media/tv, /media/movies              │
                    │            │                              │
                    │            ▼                              │
                    └──── Plex ◄──────── /media/*               │
                         └──────────┬──────────────────────────┘
                                    │ NFS
                         ┌──────────▼──────────────────────────┐
                         │  SERVER-OMV (192.168.1.198)          │
                         │  /export/mediastack                  │
                         │  /data/media (26T used, 6.1T free)  │
                         └──────────────────────────────────────┘
```

## Docker Services

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| Plex | lscr.io/linuxserver/plex | 32400 | Media server |
| Sonarr | lscr.io/linuxserver/sonarr | 8989 | TV show management |
| Radarr | lscr.io/linuxserver/radarr | 7878 | Movie management |
| Prowlarr | lscr.io/linuxserver/prowlarr | 9696 | Indexer management |
| SABnzbd | lscr.io/linuxserver/sabnzbd | 8080 | Usenet downloader |
| Overseerr | lscr.io/linuxserver/overseerr | 5055 | Media request UI |
| Bazarr | lscr.io/linuxserver/bazarr | 6767 | Subtitle management |

## NFS Mount Layout

Mount OMV `/export/mediastack` on VM 110:

```
/media/                     ← NFS mount from OMV
├── movies/                 ← Radarr library
├── tv/                     ← Sonarr library
├── music/                  ← Optional (Lidarr)
└── downloads/
    ├── complete/           ← SABnzbd completed
    └── incomplete/         ← SABnzbd in-progress
```

### /etc/fstab entry

```
192.168.1.198:/export/mediastack  /media  nfs  rw,hard,intr,nfsvers=4  0  0
```

## Docker Volume Layout

```
/opt/mediastack/            ← Docker configs (on VM local disk)
├── docker-compose.yml
├── plex/
├── sonarr/
├── radarr/
├── prowlarr/
├── sabnzbd/
├── overseerr/
└── bazarr/
```

App configs stay on local SSD (fast), media stays on NFS (large).

## Migration Steps

### Phase 1 — Prepare VM & NFS

- [ ] Verify VM 110 resources (consider bumping RAM to 8 GiB for Plex transcoding)
- [ ] Mount NFS share from OMV on VM 110
- [ ] Verify NFS read/write from VM 110
- [ ] Install Docker and Docker Compose on VM 110

### Phase 2 — Deploy ARR Suite (new services first)

- [ ] Create `/opt/mediastack/docker-compose.yml`
- [ ] Deploy Prowlarr — configure indexers
- [ ] Deploy Sonarr — configure media paths, quality profiles
- [ ] Deploy Radarr — configure media paths, quality profiles
- [ ] Deploy Bazarr — connect to Sonarr/Radarr
- [ ] Deploy Overseerr — connect to Sonarr/Radarr/Plex
- [ ] Test full pipeline: request → search → download → import

### Phase 3 — Migrate existing services

- [ ] **SABnzbd:** Export config from CT 206, import into Docker SABnzbd
- [ ] **Plex:** Migrate Plex database/metadata from CT 203 to Docker Plex
  - Copy `/var/lib/plexmediaserver` from CT 203
  - Update library paths to new NFS mount
  - Claim server with same Plex account
- [ ] Update NPM routes:
  - `plex.wueblu.com` → 192.168.1.110:32400
  - `sab.wueblu.com` → 192.168.1.110:8080
- [ ] Verify all services working via reverse proxy

### Phase 4 — Decommission legacy containers

- [ ] Stop CT 203 (plex) — keep for 2 weeks as fallback
- [ ] Stop CT 206 (sabnzbd) — keep for 2 weeks as fallback
- [ ] Stop CT 201 (data) — keep for 2 weeks as fallback
- [ ] Remove old containers after validation period
- [ ] Reclaim disk space on ZFS pool `ct`

## NPM Routes (after migration)

| Domain | Backend | Port |
|--------|---------|------|
| plex.wueblu.com | 192.168.1.110 | 32400 |
| sab.wueblu.com | 192.168.1.110 | 8080 |
| *sonarr.wueblu.com* | 192.168.1.110 | 8989 |
| *radarr.wueblu.com* | 192.168.1.110 | 7878 |
| *overseerr.wueblu.com* | 192.168.1.110 | 5055 |

*Italic = optional, could be internal-only behind WireGuard.*

## Resource Considerations

| Resource | Current (VM 110) | Recommended |
|----------|-----------------|-------------|
| RAM | 4 GiB | 8 GiB (Plex transcoding) |
| Disk | 32G | 32G (configs only, media on NFS) |
| CPU | TBD | 4+ cores |

## OMV Side — NFS Adjustments

The current NFS export restricts `/export/mediastack` to `192.168.1.110` (good). Verify:

- UID/GID mapping matches Docker PUID/PGID (currently anonuid=1000, anongid=1000)
- Sufficient space on OMV data pool for downloads (6.1T free)
- Consider separate download location if you want to avoid filling the media pool

## Risks

- **Plex metadata migration** is the trickiest part — test restore before cutting over
- **NFS performance** for Plex direct play should be fine; transcoding may need local cache
- **RAM** at 4 GiB is tight for all 7 containers — monitor and increase if needed
