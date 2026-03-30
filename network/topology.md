# Network Topology

## Subnets

| Subnet | Interface | Gateway | Purpose |
|--------|-----------|---------|---------|
| 192.168.0.0/23 | vmbr0 (eno1) | 192.168.0.1 | Main LAN (192.168.0.1 – 192.168.1.254) |
| 172.16.0.0/24 | vmbr1 (eno2) | — | Secondary network |

## Key Hosts

| Host | IP Address | Role |
|------|------------|------|
| pve | 192.168.1.199 | Proxmox hypervisor |
| SERVER-OMV | 192.168.1.198 | NAS / Backups (OpenMediaVault) |
| Gateway/Router | 192.168.0.1 | Default gateway |

## VM IP Addresses

| IP | Name | Type | Purpose |
|----|------|------|---------|
| 192.168.1.20 | home-assistant | VM 104 | Home Assistant |
| 192.168.1.21 | OpenCCU | VM 105 | HomeMatic CCU |
| 192.168.1.101 | wireguard | VM 101 | VPN |
| 192.168.1.103 | cctv | VM 103 | Surveillance |
| 192.168.1.110 | mediastack | VM 110 | Media services |
| 192.168.1.120 | aiplatform | VM 120 | AI platform |
| 192.168.1.121 | nextcloud-dpsg | VM 121 | Nextcloud |
| 192.168.1.122 | nextcloud-wueblu | VM 122 | Nextcloud |
| 192.168.1.123 | nextcloud-test | VM 123 | Nextcloud |
| 192.168.1.124 | nextcloud-vogt | VM 124 | Nextcloud |

## Container IP Addresses

| IP | Name | Type | Purpose |
|----|------|------|---------|
| 192.168.1.200 | nginxproxymanager | CT 200 | Reverse proxy |
| 192.168.1.201 | data | CT 201 | Data services |
| 192.168.1.203 | plex | CT 203 | Plex Media Server |
| 192.168.1.204 | adguard | CT 204 | DNS ad blocking |
| 192.168.1.206 | sabnzbd | CT 206 | Usenet downloader |
| 192.168.1.210 | pretix | CT 210 | Ticketing |
| 192.168.1.211 | limesurvey | CT 211 | Surveys |
| 192.168.1.214 | minecraft-dpsg | CT 214 | Minecraft server |

## DNS

- **Internal DNS server:** AdGuard Home @ 192.168.1.204
- **Domain:** `TODO`

## Firewall

- Proxmox firewall: **disabled**

## Diagram

```
Internet
  │
  ▼
[Router/Gateway 192.168.0.1]
  │
  ├── vmbr0 (192.168.0.0/23) ── Main LAN
  │     ├── pve .................. 192.168.1.199 (Proxmox)
  │     ├── SERVER-OMV ........... 192.168.1.198 (NAS)
  │     ├── home-assistant ....... 192.168.1.20
  │     ├── OpenCCU .............. 192.168.1.21
  │     ├── wireguard ............ 192.168.1.101
  │     ├── cctv ................. 192.168.1.103
  │     ├── mediastack ........... 192.168.1.110
  │     ├── aiplatform ........... 192.168.1.120
  │     ├── nextcloud-dpsg ....... 192.168.1.121
  │     ├── nextcloud-wueblu ..... 192.168.1.122
  │     ├── nextcloud-test ....... 192.168.1.123
  │     ├── nextcloud-vogt ....... 192.168.1.124
  │     ├── nginxproxymanager .... 192.168.1.200
  │     ├── data ................. 192.168.1.201
  │     ├── plex ................. 192.168.1.203
  │     ├── adguard .............. 192.168.1.204
  │     ├── sabnzbd .............. 192.168.1.206
  │     ├── pretix ............... 192.168.1.210
  │     ├── limesurvey ........... 192.168.1.211
  │     └── minecraft-dpsg ....... 192.168.1.214
  │
  └── vmbr1 (172.16.0.0/24) ── Secondary network
        └── pve .................. 172.16.0.5
```
