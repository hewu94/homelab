# OpenMediaVault Server

- **Hostname:** SERVER-OMV
- **IP:** 192.168.1.198
- **Web UI:** http://192.168.1.198
- **OS:** OpenMediaVault (Debian 12 bookworm)
- **Kernel:** 6.12.57+deb12-amd64
- **Hardware:** Supermicro Super Server
- **CPU:** Intel Pentium G4560 @ 3.50GHz (2 cores / 4 threads)
- **RAM:** 31 GiB (+975 MiB swap)
- **Role:** Media files & Backups

## Physical Disks

| Device | Size | Type | Purpose |
|--------|------|------|---------|
| nvme0n1 | 476.9G | NVMe | Boot (root 475.5G, EFI 512M, swap 976M) |
| sda | 3.6T | HDD | ZFS pool (data) |
| sdb | 3.6T | HDD | ZFS pool (data) |
| sdc | 10.9T | HDD | Backup (/media/backup) |
| sdd | 3.6T | HDD | ZFS pool (data) |
| sde | 3.6T | HDD | ZFS pool (data) |
| sdf | 3.6T | HDD | ZFS pool (data) |
| sdg | 3.6T | HDD | ZFS pool (data) |
| sdh | 3.6T | HDD | ZFS pool (data) |
| sdi | 3.6T | HDD | ZFS pool (data) |
| sdj | 3.6T | HDD | ZFS pool (data) |
| sdk | 3.6T | HDD | ZFS pool (data) |

## ZFS Pools

### data — RAIDZ1 (10x 4TB HDD)

| Pool | Layout | Total | Used | Free | Mountpoint |
|------|--------|-------|------|------|------------|
| data | raidz1 (10 drives) | 6.3T | 130G | 6.1T | /data |
| data/media | dataset | 33T | 26T | 6.1T | /data/media |

```
raidz1-0:
  3x Seagate IronWolf ST4000VN008 4TB (ZGY27EHC, ZGY3Y0W7, ZGY3XMZN)
  2x Seagate IronWolf ST4000VN008 4TB (ZDH3JFVS, ZGY27EK3)
  3x WDC WD40EFRX 4TB (WCC7K4RFLP9H, WCC7K2PER722, WCC7K6ND6Z13)
  1x WDC WD40EFPX 4TB (WXL2D33371DA)
  1x WDC WD40EFRX 4TB (WCC4E3AF80HA)
```

Last scrub: 2026-03-08 — 0 errors

> **Note:** Pool has features pending upgrade. Run `zpool upgrade` when ready (one-way operation).

## Backup Storage

| Device | Size | Used | Free | Mountpoint |
|--------|------|------|------|------------|
| sdc1 | 11T | 2.5T | 7.8T | /media/backup |

## NFS Shares

| Export | Allowed Clients | Access | Purpose |
|--------|----------------|--------|---------|
| /export/media | 192.168.0.0/23 | rw | Media files |
| /export/test | 192.168.0.0/23 | rw | Test share |
| /export/mediastack | 192.168.1.110 | rw | Mediastack VM (VMID 110) |
| /export | 192.168.0.0/23, 192.168.1.110 | ro | NFS root (read-only) |

All rw shares use `all_squash` with mapped uid/gid.

## SMB / Samba

Samba is configured but **no shares are currently defined** in `/etc/samba/smb.conf`.

- Workgroup: `WORKGROUP`
- Min protocol: SMB2_02
- Apple Time Machine support: enabled (fruit)
- NetBIOS: disabled

> Shares may be managed via the OMV web UI and not yet created, or served via NFS instead.

- Media pool (data/media) at 82% — 26T of 33T used, monitor growth
- Boot drive barely used: 6.6G/467G (2%)
- 24G/31G RAM in use, swap mostly free
- TODO: Document ZFS pool composition (which disks, RAIDZ level)
- TODO: Document SMB/NFS share settings
- TODO: Document backup schedules and sources
