# Maintenance

## Backup Schedule (Proxmox vzdump)

| Schedule | VMs/CTs | Target | Retention | Notes |
|----------|---------|--------|-----------|-------|
| Daily 3:00 | 121, 122, 123, 124 (Nextcloud) | usbBackup (7.3T USB) | last=3, daily=1, monthly=1 | zstd, offsite copy |
| Daily 4:30 | 121, 122, 123, 124 (Nextcloud) | localBackup | last=3, daily=1, weekly=1, monthly=1 | zstd, fleecing enabled |
| Sun 1:00 | 200, 210, 214 (Containers) | localBackup | default | zstd |
| Sun 2:00 | 101, 103, 104, 105, 110, 120 (Core VMs) | localBackup | default | zstd |

### Not Backed Up

- CT 201 (data), CT 203 (plex), CT 204 (adguard), CT 206 (sabnzbd), CT 211 (limesurvey)
- All stopped: CT 207 (minecraft), CT 212 (dpsg-dolibarr), CT 213 (vogt-lime)

## ZFS Scrub Schedule

| Pool | Host | Last Scrub | Result |
|------|------|------------|--------|
| ct | pve | 2026-03-08 | 0 errors |
| data | pve | 2026-03-08 | 0 errors |
| ssd | pve | 2026-03-08 | 0 errors |
| data | SERVER-OMV | 2026-03-08 | 0 errors |

## Update Schedule

- **OS updates:** `TODO`
- **Container updates:** `TODO`

## Runbooks

- [TODO: Add runbooks for common maintenance tasks]
