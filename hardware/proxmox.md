# Proxmox Server

- **Hostname:** pve
- **IP:** 192.168.1.199
- **Web UI:** https://192.168.1.199:8006
- **OS:** Proxmox VE (Debian 12 bookworm)
- **Kernel:** 6.8.12-20-pve
- **Hardware:** Supermicro X10SRA
- **CPU:** Intel Xeon E5-2690 v4 @ 2.60GHz (14 cores / 28 threads)
- **RAM:** 94 GiB (+8 GiB swap)

## Virtual Machines

| VMID | Name | IP | RAM | Disk | Status | Purpose |
|------|------|----|-----|------|--------|---------|
| 101 | wireguard | 192.168.1.101 | 2 GiB | 10G | running | VPN (WireGuard) |
| 103 | cctv | 192.168.1.103 | 8 GiB | 32G | running | CCTV / Surveillance |
| 104 | home-assistant | 192.168.1.20 | 8 GiB | 32G | running | Home Assistant |
| 105 | OpenCCU | 192.168.1.21 | 2 GiB | 6G | running | HomeMatic CCU |
| 110 | mediastack | 192.168.1.110 | 4 GiB | 32G | running | Media services |
| 120 | aiplatform | 192.168.1.120 | 16 GiB | 128G | running | AI platform (GPU) |
| 121 | nextcloud-dpsg | 192.168.1.121 | 16 GiB | 32G | running | Nextcloud (DPSG) |
| 122 | nextcloud-wueblu | 192.168.1.122 | 8 GiB | 32G | running | Nextcloud (Wueblu) |
| 123 | nextcloud-test | 192.168.1.123 | 8 GiB | 32G | running | Nextcloud (test) |
| 124 | nextcloud-vogt | 192.168.1.124 | 8 GiB | 32G | running | Nextcloud (Vogt) |

## Containers (LXC)

| CTID | Name | IP | Disk | Status | Purpose |
|------|------|----|------|--------|---------|
| 200 | nginxproxymanager | 192.168.1.200 | 4G | running | Reverse proxy (Nginx Proxy Manager) |
| 201 | data | 192.168.1.201 | 8G | running | Data services |
| 203 | plex | 192.168.1.203 | 64G | running | Plex Media Server |
| 204 | adguard | 192.168.1.204 | 2G | running | DNS ad blocking (AdGuard Home) |
| 206 | sabnzbd | 192.168.1.206 | 8G | running | Usenet downloader (SABnzbd) |
| 207 | minecraft | — | 16G | stopped | Minecraft server |
| 210 | pretix | 192.168.1.210 | 16G | running | Ticketing (Pretix) |
| 211 | limesurvey | 192.168.1.211 | 8G | running | Surveys (LimeSurvey) |
| 212 | dpsg-dolibarr | — | 16G | stopped | ERP (Dolibarr, DPSG) |
| 213 | vogt-lime | — | 8G | stopped | LimeSurvey (Vogt) |
| 214 | minecraft-dpsg | 192.168.1.214 | 8G | running | Minecraft server (DPSG) |

## Physical Disks

| Device | Size | Type | Purpose |
|--------|------|------|---------|
| sda | 3.6T | HDD | ZFS pool |
| sdb | 3.6T | HDD | ZFS pool |
| sdc | 3.6T | HDD | ZFS pool |
| sdd | 3.6T | HDD | ZFS pool |
| sde | 930.5G | SSD | Boot (LVM: pve-root 96G, pve-swap 8G, pve-data 794G) |
| sdf | 238.5G | SSD | ZFS pool |
| sdg | 238.5G | SSD | ZFS pool |
| sdh | 238.5G | SSD | ZFS pool |
| sdi | 3.6T | HDD | ZFS pool |
| sdj | 238.5G | SSD | ZFS pool |
| sdk | 7.3T | USB | Backup (/mnt/pve/usbBackup) |
| nvme0n1 | 1.8T | NVMe | LVM (win_vm) |
| nvme1n1 | 1.8T | NVMe | ZFS pool |
| nvme2n1 | 1.8T | NVMe | ZFS pool |
| nvme3n1 | 1.8T | NVMe | ZFS pool |
| nvme4n1 | 1.8T | NVMe | ZFS pool |

## ZFS Pools

### ct — Container Storage (Mirror)

| Pool | Layout | Size | Mountpoint |
|------|--------|------|------------|
| ct | 2x mirror (4x SanDisk 256G SSD) | 183G | /ct |

```
mirror-0: SanDisk SDSSDH3 256G (×2)
mirror-1: SanDisk SDSSDH3 256G (×2)
```

Last scrub: 2026-03-08 — 0 errors

### data — HDD Data Pool (RAIDZ1)

| Pool | Layout | Size | Mountpoint |
|------|--------|------|------------|
| data | raidz1 (5x WD Red 4T) | 7.8T | /data |

```
raidz1-0: 5x WDC WD40EFZX 4TB
```

Last scrub: 2026-03-08 — 0 errors

### ssd — NVMe Storage (RAIDZ1)

| Pool | Layout | Size | Mountpoint |
|------|--------|------|------------|
| ssd | raidz1 (4x WD Red SN700 2T NVMe) | 892G | /ssd |

```
raidz1-0: 4x WD Red SN700 2TB NVMe
```

Last scrub: 2026-03-08 — 0 errors

## Network Bridges

| Bridge | IP | Subnet | Port | Purpose |
|--------|----|--------|------|---------|
| vmbr0 | 192.168.1.199 | /23 | eno1 | Main LAN (gateway 192.168.0.1) |
| vmbr1 | 172.16.0.5 | /24 | eno2 | Secondary network |

## GPU

- **NVIDIA GeForce GTX 1070** (8 GiB VRAM)
- Driver: 580.126.20, CUDA: 13.0
- PCI passthrough to aiplatform (VM 120)
- Persistence mode: on
- Power: 12W idle / 151W cap
- Host crontab has `@reboot nvidia-smi -pm 1 && nvidia-smi -pl 250` — likely stale (GPU not visible to host)

## Backup Jobs

| Schedule | VMs/CTs | Target | Retention | Notes |
|----------|---------|--------|-----------|-------|
| Daily 4:30 | 121, 122, 123, 124 (Nextcloud) | localBackup | last=3, daily=1, weekly=1, monthly=1 | zstd, fleecing enabled |
| Daily 3:00 | 121, 122, 123, 124 (Nextcloud) | usbBackup | last=3, daily=1, monthly=1 | zstd, offsite copy |
| Sun 2:00 | 101, 103, 104, 105, 110, 120 (Core VMs) | localBackup | default | zstd |
| Sun 1:00 | 200, 210, 214 (Containers) | localBackup | default | zstd |

## Notes

- USB backup drive (7.3T) mounted at /mnt/pve/usbBackup, 304G used
- Boot drive 32% used (29G/94G)
- RAM nearly full: 89G/94G used + swap fully used
- Firewall: disabled
- Nextcloud VMs backed up both locally and to USB (redundant)
- Containers 201 (data), 203 (plex), 204 (adguard), 206 (sabnzbd), 211 (limesurvey) are NOT backed up
- Stopped VMs/CTs (207, 212, 213) are NOT backed up
