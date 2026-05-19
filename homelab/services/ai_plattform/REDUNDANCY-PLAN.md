# Nextcloud Geo-Redundancy Plan

> **Goal:** Run standby replicas of all 4 Nextcloud instances on a second server at a remote location with **automatic failover** when the primary becomes unreachable.  
> **Scope:** Nextcloud only — AI platform (Ollama, CCB, LocalAI, Open WebUI) stays primary-only.  
> **Constraint:** Remote/standby server is **IPv6-only** — requires Cloudflare Tunnel for IPv4 client access.  
> **Constraint:** Both sites have **dynamic IPs** (no static) — requires DynDNS for WireGuard endpoints and Cloudflare A record updates.  
> **Date:** 2026-05-19

---

## Table of Contents

1. [Current State](#1-current-state)
2. [Architecture Overview](#2-architecture-overview)
3. [Remote Server Requirements](#3-remote-server-requirements)
4. [Phase 1 — Site-to-Site VPN (WireGuard over IPv6)](#4-phase-1--site-to-site-vpn-wireguard-over-ipv6)
5. [Phase 2 — Remote Server Base Setup](#5-phase-2--remote-server-base-setup)
6. [Phase 3 — Cloudflare Tunnel & DNS](#6-phase-3--cloudflare-tunnel--dns)
7. [Phase 4 — Database Replication](#7-phase-4--database-replication)
8. [Phase 5 — File Storage Sync](#8-phase-5--file-storage-sync)
9. [Phase 6 — Nextcloud Standby Instances](#9-phase-6--nextcloud-standby-instances)
10. [Phase 7 — Automatic Failover Daemon](#10-phase-7--automatic-failover-daemon)
11. [Phase 8 — Monitoring & Alerting](#11-phase-8--monitoring--alerting)
12. [Phase 9 — Failover Procedure (Automated)](#12-phase-9--failover-procedure-automated)
13. [Phase 10 — Failback Procedure (Manual)](#13-phase-10--failback-procedure-manual)
14. [Changes Required at the Primary Site](#14-changes-required-at-the-primary-site)
15. [Appendix A — Decision: AIO vs. Manual Nextcloud](#appendix-a--decision-aio-vs-manual-nextcloud)
16. [Appendix B — IPv6-Only: Why Cloudflare Tunnel](#appendix-b--ipv6-only-why-cloudflare-tunnel)
17. [Appendix C — Bandwidth Estimation](#appendix-c--bandwidth-estimation)
18. [Appendix D — Replication Topology Diagram](#appendix-d--replication-topology-diagram)

---

## 1. Current State

### Primary Site (Home)

| Component | Host | IP | Details |
|---|---|---|---|
| Proxmox | pve | 192.168.1.199 | Xeon E5-2690 v4, 94 GiB RAM |
| NC1 (DPSG) | VM 121 | 192.168.1.121 | AIO, 16 GiB RAM, `dpsg-bruenninghausen.de` |
| NC2 (Wueblu) | VM 122 | 192.168.1.122 | AIO, 8 GiB RAM, `cloud.wueblu.com` |
| NC3 (Test) | VM 123 | 192.168.1.123 | AIO, 8 GiB RAM, `test.dpsg-bruenninghausen.de` |
| NC4 (Vogt) | VM 124 | 192.168.1.124 | AIO, 8 GiB RAM, `vogt-cloud.de` |
| AI Platform | VM 120 | 192.168.1.120 | GPU VM — NOT replicated |
| Reverse Proxy | CT 200 | 192.168.1.200 | Nginx Proxy Manager |
| WireGuard | VM 101 | 192.168.1.101 | VPN server |
| NAS | SERVER-OMV | 192.168.1.198 | 33T ZFS, backups |

### DNS / Domain Registrar

All domains are registered and managed through **Netcup** (netcup.de):

| Domain | Registrar | Current DNS |
|---|---|---|
| `dpsg-bruenninghausen.de` | Netcup | Netcup DNS |
| `wueblu.com` | Netcup | Netcup DNS |
| `vogt-cloud.de` | Netcup | Netcup DNS |

> NS records must be changed at Netcup's CCP (Customer Control Panel) to point to Cloudflare for the failover mechanism to work.

### Each Nextcloud AIO Instance Consists Of

- **Nextcloud AIO mastercontainer** — manages the stack
- **nextcloud-aio-nextcloud** — PHP app
- **nextcloud-aio-database** — PostgreSQL
- **nextcloud-aio-redis** — session/cache
- **nextcloud-aio-apache** — HTTPS termination (self-signed, behind NPM)
- **nextcloud-aio-notify-push** — push notifications via websocket
- **Data volume** — `/var/lib/docker/volumes/nextcloud_aio_nextcloud_data`

---

## 2. Architecture Overview

```
PRIMARY SITE (Home, IPv4)                     REMOTE SITE (IPv6-only)
┌──────────────────────────────┐              ┌──────────────────────────────┐
│  Proxmox (pve)               │              │  Remote Server               │
│                              │              │                              │
│  ┌──────────┐ ┌──────────┐   │  WireGuard   │  ┌──────────┐ ┌──────────┐  │
│  │ NC1 AIO  │ │ NC2 AIO  │   │  (over IPv6) │  │ NC1 stby │ │ NC2 stby │  │
│  │ (active) │ │ (active) │   │◄────────────►│  │ (cold)   │ │ (cold)   │  │
│  └──────────┘ └──────────┘   │  10.10.10    │  └──────────┘ └──────────┘  │
│  ┌──────────┐ ┌──────────┐   │  .0/24       │  ┌──────────┐ ┌──────────┐  │
│  │ NC3 AIO  │ │ NC4 AIO  │   │  DB repli-   │  │ NC3 stby │ │ NC4 stby │  │
│  │ (active) │ │ (active) │   │  cation +    │  │ (cold)   │ │ (cold)   │  │
│  └──────────┘ └──────────┘   │  file sync   │  └──────────┘ └──────────┘  │
│                              │              │                              │
│  ┌──────────┐                │              │  ┌────────────────────────┐  │
│  │ AI Plat. │  (NOT repli-   │              │  │ cloudflared (tunnel)   │  │
│  │ (GPU VM) │   cated)       │              │  │  → Cloudflare edge     │  │
│  └──────────┘                │              │  └────────────────────────┘  │
│                              │              │                              │
│  ┌──────────┐                │              │  ┌────────────────────────┐  │
│  │ NPM      │                │              │  │ nc-failover (daemon)   │  │
│  │ (proxy)  │                │              │  │  monitors primary      │  │
│  └──────────┘                │              │  │  auto-triggers switch  │  │
└──────────────────────────────┘              │  └────────────────────────┘  │
         │                                    └──────────────────────────────┘
         │            ┌──────────────┐                     │
         └───────────►│  Cloudflare  │◄────────────────────┘
           IPv4 A     │  (proxy)     │  cloudflared tunnel
           record     │              │  (outbound IPv6)
                      │  Serves both │
                      │  IPv4 + IPv6 │
                      │  to clients  │
                      └──────┬───────┘
                             │
                          Clients
                      (IPv4 or IPv6)
```

### How Traffic Flows

| State | Client → Cloudflare | Cloudflare → Origin |
|---|---|---|
| **Normal** | `dpsg-bruenninghausen.de` → CF edge | CF → primary (IPv4 A record, port-forwarded) |
| **Failover** | `dpsg-bruenninghausen.de` → CF edge | CF → standby via `cloudflared` tunnel (IPv6) |

> **Key insight:** Cloudflare Tunnel solves the IPv6-only problem. The tunnel daemon (`cloudflared`) runs on the standby and makes an **outbound** connection to Cloudflare's edge. No inbound ports, no public IPv4 needed. Clients always connect to Cloudflare's anycast (IPv4 + IPv6) regardless of the origin's protocol.

### Design Decisions

| Decision | Rationale |
|---|---|
| **Cold standby + warm data** | Containers stopped, but data continuously synced; fast activation |
| **Automatic failover** | Health-check daemon on remote detects outage, triggers failover without human intervention |
| **Manual failback** | Prevents split-brain; human verifies primary is healthy before switching back |
| **Cloudflare Tunnel** (not direct IPv6) | Standby is IPv6-only — tunnel provides IPv4 access for all clients |
| **Cloudflare Proxy** (orange cloud) | Hides origin IP, provides WAF/DDoS protection, serves IPv4+IPv6 |
| **DynDNS for WireGuard** | Both sites have dynamic IPs — DynDNS hostnames used as WireGuard endpoints |
| **DynDNS for Cloudflare A record** | Primary's dynamic IPv4 kept in sync with Cloudflare via API updater cron |
| **pg_dump + rsync** | AIO controls its own containers tightly; logical backups are more reliable than streaming replication |
| **Separate Nextcloud installs** (not AIO) on remote | AIO's mastercontainer complicates replication — remote runs manual Nextcloud + Docker Compose |
| **AI stays primary-only** | GPU-dependent, no GPU at remote, users accept degraded AI during failover |
| **WireGuard over IPv6** | Site-to-site tunnel uses IPv6 transport; provides IPv4 overlay (10.10.10.0/24) for replication |

---

## 3. Remote Server Requirements

### Minimum Hardware

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 4 cores | 8+ cores | Serves 4 NC instances during failover |
| RAM | 16 GiB | 32 GiB | ~4 GiB per NC instance + OS overhead |
| Boot disk | 64 GB SSD | 128 GB NVMe | OS + Docker images |
| Data disk | Match NC data size | 2x HDD/SSD in mirror | All NC file storage + DB |
| Network | 50 Mbit/s symmetric | 100+ Mbit/s | For replication traffic + user access during failover |
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS | Match primary for consistency |

### Network Requirements (IPv6)

| Requirement | Details |
|---|---|
| Public IPv6 address (dynamic OK) | Assigned by ISP — may change on reconnect |
| IPv6 firewall | Allow outbound HTTPS (cloudflared), WireGuard UDP |
| No public IPv4 needed | Cloudflare Tunnel handles IPv4 client access |
| WireGuard endpoint | Uses DynDNS hostname (not raw IP) since both sites have dynamic IPs |
| DynDNS service | Both sites need a DynDNS hostname for WireGuard peer resolution |

### Software Stack

- Docker + Docker Compose
- WireGuard (IPv6 transport)
- `cloudflared` (Cloudflare Tunnel daemon)
- PostgreSQL 16 client tools (for `pg_restore`)
- rsync
- Python 3 (for failover daemon)

---

## 4. Phase 1 — Site-to-Site VPN (WireGuard over IPv6)

Connect both sites over an encrypted tunnel so DB replication and rsync run securely. The tunnel uses **IPv6 as transport** (since the remote is IPv6-only) but provides an **IPv4 overlay** (10.10.10.0/24) for service communication.

Since both sites have **dynamic IPs**, WireGuard endpoints use **DynDNS hostnames** instead of static addresses.

### 4.0 DynDNS Setup (Both Sites)

Both sites need a stable hostname that tracks their changing IP. Choose **one** DynDNS approach:

| Provider | Protocol | IPv6 Support | Cost | Notes |
|---|---|---|---|---|
| **DuckDNS** | HTTPS API | ✅ | Free | Simple, reliable, good default |
| **Cloudflare subdomains** | API | ✅ | Free (already using) | Reuse existing CF account |
| **Fritz!Box MyFRITZ!** | Built-in | ✅ | Free | If using Fritz!Box router |
| **No-IP / DynDNS** | DynDNS2 | ✅ | Free tier | Classic, broad router support |

#### Option A: DuckDNS (Recommended for simplicity)

```bash
# On BOTH sites — update every 5 minutes via cron

# Primary site (dual-stack or IPv4):
echo '*/5 * * * * curl -s "https://www.duckdns.org/update?domains=homelab-primary&token=<duckdns-token>&ipv6=auto&ip=" > /dev/null' | sudo crontab -

# Remote site (IPv6-only):
echo '*/5 * * * * curl -s "https://www.duckdns.org/update?domains=homelab-remote&token=<duckdns-token>&ipv6=auto&ip=" > /dev/null' | sudo crontab -
```

Result:
- `homelab-primary.duckdns.org` → always resolves to primary's current public IP
- `homelab-remote.duckdns.org` → always resolves to remote's current public IPv6

#### Option B: Cloudflare DynDNS (Use existing CF account)

Since you're already using Cloudflare, create dedicated subdomains for WireGuard endpoints and update them via API:

```bash
# /opt/dyndns/cf-dyndns.sh — run on both sites (adjust record names)
#!/bin/bash
set -euo pipefail

CF_TOKEN="<cloudflare-api-token>"
ZONE_ID="<zone-id>"
# Primary: wg-primary.dpsg-bruenninghausen.de
# Remote:  wg-remote.dpsg-bruenninghausen.de
RECORD_NAME="wg-primary.dpsg-bruenninghausen.de"  # DNS-only, NOT proxied!
RECORD_ID_A="<a-record-id>"       # for IPv4
RECORD_ID_AAAA="<aaaa-record-id>" # for IPv6

# Get current public IPv4
CURRENT_IPV4=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
# Get current public IPv6
CURRENT_IPV6=$(curl -s6 --max-time 5 https://ifconfig.me 2>/dev/null || echo "")

# Update A record (IPv4)
if [[ -n "$CURRENT_IPV4" ]]; then
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID_A" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"content\":\"$CURRENT_IPV4\",\"proxied\":false}" > /dev/null
fi

# Update AAAA record (IPv6)
if [[ -n "$CURRENT_IPV6" ]]; then
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID_AAAA" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"content\":\"$CURRENT_IPV6\",\"proxied\":false}" > /dev/null
fi
```

```bash
# Cron — both sites, every 5 minutes
*/5 * * * * /opt/dyndns/cf-dyndns.sh 2>&1 | logger -t cf-dyndns
```

> **Important:** These WireGuard DynDNS records must be **DNS-only** (grey cloud ☁️), NOT proxied. Proxied records route through Cloudflare's edge, which adds latency and can't carry WireGuard UDP.

### 4.0.1 WireGuard + Dynamic Endpoints: Re-Resolution

WireGuard resolves `Endpoint` hostnames **only at startup**. If the remote peer's IP changes, WireGuard won't notice until the interface is restarted.

Fix with a **reresolve-dns cron** on both sites:

```bash
# /opt/wireguard/reresolve-dns.sh
#!/bin/bash
# Re-resolve WireGuard peer endpoints periodically
# Handles dynamic IP changes on the remote peer

WG_INTERFACE="wg-site"

# Get current peer endpoint hostname from config
PEER_ENDPOINT=$(grep -i 'Endpoint' /etc/wireguard/${WG_INTERFACE}.conf | awk '{print $3}' | sed 's/\[//;s/\]:.*//' | head -1)
PEER_PORT=$(grep -i 'Endpoint' /etc/wireguard/${WG_INTERFACE}.conf | awk '{print $3}' | grep -oP ':\K[0-9]+' | head -1)
PEER_PUBKEY=$(grep -A5 '\[Peer\]' /etc/wireguard/${WG_INTERFACE}.conf | grep 'PublicKey' | awk '{print $3}' | head -1)

if [[ -z "$PEER_ENDPOINT" || -z "$PEER_PORT" || -z "$PEER_PUBKEY" ]]; then
  exit 0
fi

# Resolve hostname to current IP
RESOLVED=$(getent hosts "$PEER_ENDPOINT" | awk '{print $1}' | head -1)

if [[ -n "$RESOLVED" ]]; then
  # Check if it's IPv6 (contains colon)
  if [[ "$RESOLVED" == *:* ]]; then
    wg set "$WG_INTERFACE" peer "$PEER_PUBKEY" endpoint "[$RESOLVED]:$PEER_PORT"
  else
    wg set "$WG_INTERFACE" peer "$PEER_PUBKEY" endpoint "$RESOLVED:$PEER_PORT"
  fi
fi
```

```bash
chmod +x /opt/wireguard/reresolve-dns.sh
# Run every 2 minutes on BOTH sites
echo '*/2 * * * * /opt/wireguard/reresolve-dns.sh 2>/dev/null' | sudo tee -a /etc/cron.d/wg-reresolve
```

### 4.1 Tunnel Network

| Parameter | Value |
|---|---|
| Tunnel subnet | `10.10.10.0/24` (IPv4 overlay inside tunnel) |
| Primary endpoint | `10.10.10.1` (VM 101 or dedicated) |
| Remote endpoint | `10.10.10.2` |
| Port | `51821/udp` |
| Transport | **IPv6** (remote endpoint is an IPv6 address) |
| Keepalive | `25` seconds |
| Primary DynDNS | `homelab-primary.duckdns.org` (or `wg-primary.dpsg-bruenninghausen.de`) |
| Remote DynDNS | `homelab-remote.duckdns.org` (or `wg-remote.dpsg-bruenninghausen.de`) |

> **Important:** The primary WireGuard server (VM 101) needs IPv6 connectivity to accept connections from the IPv6-only remote. If the primary router supports IPv6 (even dual-stack), this works. If the primary has no IPv6, use a relay (see note below).

### 4.2 Primary Site — WireGuard Config (VM 101)

Add a new peer for the remote site. The `Endpoint` uses the remote's **DynDNS hostname**:

```ini
# /etc/wireguard/wg-site.conf (new interface or add peer to wg0)
[Interface]
Address = 10.10.10.1/24
ListenPort = 51821
PrivateKey = <primary-private-key>

# Allow forwarding to LAN for DB replication
PostUp = iptables -A FORWARD -i wg-site -o eno1 -j ACCEPT; iptables -A FORWARD -i eno1 -o wg-site -j ACCEPT; iptables -t nat -A POSTROUTING -o eno1 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg-site -o eno1 -j ACCEPT; iptables -D FORWARD -i eno1 -o wg-site -j ACCEPT; iptables -t nat -D POSTROUTING -o eno1 -j MASQUERADE

[Peer]
# Remote site (IPv6-only, dynamic IP → resolved via DynDNS)
PublicKey = <remote-public-key>
AllowedIPs = 10.10.10.2/32, 192.168.50.0/24
Endpoint = homelab-remote.duckdns.org:51821
PersistentKeepalive = 25
```

### 4.3 Remote Site — WireGuard Config

```ini
# /etc/wireguard/wg-site.conf
[Interface]
Address = 10.10.10.2/24
ListenPort = 51821
PrivateKey = <remote-private-key>

[Peer]
# Primary site (dynamic IP → resolved via DynDNS)
PublicKey = <primary-public-key>
AllowedIPs = 10.10.10.1/32, 192.168.0.0/23
Endpoint = homelab-primary.duckdns.org:51821
PersistentKeepalive = 25
```

> **PersistentKeepalive = 25** is essential with dynamic IPs. It keeps the tunnel alive so the peer's last-known endpoint stays current. Combined with the reresolve cron, this handles IP changes within ~2 minutes.

### 4.4 Enable and Test

```bash
# Both sites
sudo systemctl enable --now wg-quick@wg-site

# From remote, verify tunnel
ping 10.10.10.1
# Verify access to NC DB ports through the tunnel
nc -zv 10.10.10.1 5432  # will be set up in Phase 3
```

### 4.5 Firewall Rules (Primary)

Allow the remote site to reach only the required services through the tunnel:

```bash
# On primary WireGuard host (VM 101) — or Proxmox firewall if enabled
# Allow PostgreSQL replication (5432) from remote via tunnel
iptables -A FORWARD -i wg-site -d 192.168.1.121 -p tcp --dport 5432 -j ACCEPT
iptables -A FORWARD -i wg-site -d 192.168.1.122 -p tcp --dport 5432 -j ACCEPT
iptables -A FORWARD -i wg-site -d 192.168.1.123 -p tcp --dport 5432 -j ACCEPT
iptables -A FORWARD -i wg-site -d 192.168.1.124 -p tcp --dport 5432 -j ACCEPT
# Allow rsync (22/SSH) from remote
iptables -A FORWARD -i wg-site -d 192.168.1.121 -p tcp --dport 22 -j ACCEPT
iptables -A FORWARD -i wg-site -d 192.168.1.122 -p tcp --dport 22 -j ACCEPT
iptables -A FORWARD -i wg-site -d 192.168.1.123 -p tcp --dport 22 -j ACCEPT
iptables -A FORWARD -i wg-site -d 192.168.1.124 -p tcp --dport 22 -j ACCEPT
```

---

## 5. Phase 2 — Remote Server Base Setup

### 5.1 OS Installation

```bash
# Install Ubuntu 24.04 LTS server
# Set hostname: remote-nc
# Configure static IP at the remote site's LAN (e.g., 192.168.50.10)
```

### 5.2 Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

### 5.3 Install Required Tools

```bash
sudo apt update && sudo apt install -y \
  wireguard \
  rsync \
  postgresql-client-16 \
  python3 python3-pip python3-venv \
  htop \
  iotop \
  ncdu
```

### 5.4 Install cloudflared

```bash
# Cloudflare Tunnel daemon — connects outbound to Cloudflare edge
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared
```

### 5.5 Disk Setup (if separate data disk)

```bash
# Example: /dev/sdb formatted as ext4 or ZFS
sudo mkfs.ext4 /dev/sdb
sudo mkdir -p /data
echo '/dev/sdb /data ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount -a

# Create directories for each NC instance
sudo mkdir -p /data/{nc1,nc2,nc3,nc4}/{db,files,config}
```

---

## 6. Phase 3 — Database Replication

Nextcloud AIO uses PostgreSQL. We set up **asynchronous streaming replication** from each primary DB to a standby on the remote server.

### Strategy

Since Nextcloud AIO manages its own PostgreSQL containers, we need to:
1. Expose the AIO PostgreSQL port on each NC VM
2. Configure each as a replication primary
3. Run 4 standby PostgreSQL containers on the remote server

### 6.1 Changes at Primary — Expose PostgreSQL Ports

On each Nextcloud AIO VM (121–124), the PostgreSQL container must be accessible from the WireGuard tunnel.

#### Option A: Modify AIO mastercontainer environment (Recommended)

Nextcloud AIO supports custom database ports via environment variables. Add a docker-compose override:

```bash
# On each NC VM, e.g., NC1 (192.168.1.121)
sudo mkdir -p /opt/nextcloud-aio
cat << 'EOF' | sudo tee /opt/nextcloud-aio/docker-compose.override.yml
# Expose the AIO database container port to the host
# This allows the remote standby to connect for replication
services:
  nextcloud-aio-database:
    ports:
      - "5432:5432"
EOF
```

> **Note:** If AIO manages its own compose, you may need to use a sidecar approach instead — see Option B.

#### Option B: SSH Tunnel (If AIO blocks direct port exposure)

If AIO's mastercontainer overrides custom compose changes, use an SSH tunnel from the remote site:

```bash
# On remote server — one tunnel per NC instance
autossh -M 0 -f -N -L 15432:172.18.0.X:5432 user@10.10.10.1 -p 22  # NC1
autossh -M 0 -f -N -L 25432:172.18.0.X:5432 user@10.10.10.1 -p 22  # NC2
# etc.
```

#### Option C: pg_dump / pg_restore Cron (Simplest, Recommended for AIO)

Because Nextcloud AIO tightly controls its containers, the most reliable DB replication approach is periodic **logical backups**:

```bash
# On primary VM 121 (NC1) — dump the AIO database every 15 minutes
*/15 * * * * docker exec nextcloud-aio-database pg_dump -U nextcloud nextcloud | gzip > /tmp/nc1-db-latest.sql.gz
```

Then rsync the dump to the remote site (see Phase 4).

> **Recommendation:** Start with Option C (pg_dump cron) for simplicity. Upgrade to streaming replication later if RPO < 15 minutes is needed.

### 6.2 pg_dump Cron Setup (per NC VM)

Create on each Nextcloud VM:

```bash
# /opt/nc-backup/backup-db.sh
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/opt/nc-backup/db"
mkdir -p "$BACKUP_DIR"

# Dump the AIO PostgreSQL database
docker exec nextcloud-aio-database pg_dump -U nextcloud -Fc nextcloud \
  > "$BACKUP_DIR/nextcloud-latest.dump"

# Keep last 4 dumps (1 hour of history at 15-min intervals)
find "$BACKUP_DIR" -name "nextcloud-*.dump.bak" -mmin +120 -delete
cp "$BACKUP_DIR/nextcloud-latest.dump" \
   "$BACKUP_DIR/nextcloud-$(date +%Y%m%d-%H%M).dump.bak"
```

```bash
chmod +x /opt/nc-backup/backup-db.sh
crontab -e
# Add:
*/15 * * * * /opt/nc-backup/backup-db.sh 2>&1 | logger -t nc-backup
```

### 6.3 Standby Database Containers (Remote)

On the remote server, run 4 PostgreSQL instances to receive restored backups:

```yaml
# /opt/nextcloud-standby/docker-compose.db.yml
services:
  db-nc1:
    image: postgres:16-alpine
    container_name: nc1-db-standby
    restart: unless-stopped
    environment:
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC1_DB_PASSWORD}"
      POSTGRES_DB: nextcloud
    volumes:
      - nc1_db_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:15432:5432"

  db-nc2:
    image: postgres:16-alpine
    container_name: nc2-db-standby
    restart: unless-stopped
    environment:
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC2_DB_PASSWORD}"
      POSTGRES_DB: nextcloud
    volumes:
      - nc2_db_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:25432:5432"

  db-nc3:
    image: postgres:16-alpine
    container_name: nc3-db-standby
    restart: unless-stopped
    environment:
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC3_DB_PASSWORD}"
      POSTGRES_DB: nextcloud
    volumes:
      - nc3_db_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:35432:5432"

  db-nc4:
    image: postgres:16-alpine
    container_name: nc4-db-standby
    restart: unless-stopped
    environment:
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC4_DB_PASSWORD}"
      POSTGRES_DB: nextcloud
    volumes:
      - nc4_db_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:45432:5432"

volumes:
  nc1_db_data:
  nc2_db_data:
  nc3_db_data:
  nc4_db_data:
```

### 6.4 DB Restore Script (Remote)

```bash
# /opt/nextcloud-standby/restore-db.sh
#!/bin/bash
set -euo pipefail

SYNC_DIR="/data/sync"

restore_db() {
  local instance=$1
  local port=$2
  local dump_file="$SYNC_DIR/$instance/db/nextcloud-latest.dump"

  if [[ ! -f "$dump_file" ]]; then
    echo "[$instance] No dump file found, skipping"
    return
  fi

  echo "[$instance] Restoring database..."
  PGPASSWORD="${!instance_pw}" pg_restore \
    -h 127.0.0.1 -p "$port" -U nextcloud -d nextcloud \
    --clean --if-exists --no-owner --no-privileges \
    "$dump_file" 2>/dev/null || true
  echo "[$instance] Done"
}

# Map instance passwords from environment
NC1_DB_PASSWORD="${NC1_DB_PASSWORD:-changeme}"
NC2_DB_PASSWORD="${NC2_DB_PASSWORD:-changeme}"
NC3_DB_PASSWORD="${NC3_DB_PASSWORD:-changeme}"
NC4_DB_PASSWORD="${NC4_DB_PASSWORD:-changeme}"

instance_pw="NC1_DB_PASSWORD" restore_db nc1 15432
instance_pw="NC2_DB_PASSWORD" restore_db nc2 25432
instance_pw="NC3_DB_PASSWORD" restore_db nc3 35432
instance_pw="NC4_DB_PASSWORD" restore_db nc4 45432
```

---

## 7. Phase 4 — File Storage Sync

Nextcloud data directories (user files, appdata, config) are synced from primary to remote via rsync over the WireGuard tunnel.

### 7.1 SSH Key Setup

```bash
# On remote server — generate key pair for rsync
ssh-keygen -t ed25519 -f ~/.ssh/nc-sync -N "" -C "nc-sync-remote"

# Copy public key to each NC VM
for ip in 192.168.1.121 192.168.1.122 192.168.1.123 192.168.1.124; do
  ssh-copy-id -i ~/.ssh/nc-sync.pub user@"$ip"
done
```

### 7.2 rsync Script (Remote → pulls from Primary)

```bash
# /opt/nextcloud-standby/sync-files.sh
#!/bin/bash
set -euo pipefail

SYNC_DIR="/data/sync"
LOG="/var/log/nc-sync.log"
SSH_KEY="$HOME/.ssh/nc-sync"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# WireGuard tunnel IPs (resolve to primary LAN via tunnel routing)
declare -A NC_HOSTS=(
  [nc1]="10.10.10.1"    # routes to 192.168.1.121
  [nc2]="10.10.10.1"    # routes to 192.168.1.122
  [nc3]="10.10.10.1"    # routes to 192.168.1.123
  [nc4]="10.10.10.1"    # routes to 192.168.1.124
)

# Map to actual VM IPs (used via SSH ProxyJump or direct routing)
declare -A NC_IPS=(
  [nc1]="192.168.1.121"
  [nc2]="192.168.1.122"
  [nc3]="192.168.1.123"
  [nc4]="192.168.1.124"
)

sync_instance() {
  local instance=$1
  local ip="${NC_IPS[$instance]}"
  local dest="$SYNC_DIR/$instance"
  
  echo "[$(date '+%F %T')] Syncing $instance from $ip" >> "$LOG"
  
  mkdir -p "$dest"/{files,db,config}
  
  # Sync Nextcloud data directory (user files)
  # AIO stores data in a Docker volume — the path on the host is:
  #   /var/lib/docker/volumes/nextcloud_aio_nextcloud_data/_data
  rsync -avz --delete \
    -e "ssh $SSH_OPTS" \
    "user@$ip:/var/lib/docker/volumes/nextcloud_aio_nextcloud_data/_data/" \
    "$dest/files/" \
    >> "$LOG" 2>&1

  # Sync the database dump
  rsync -avz \
    -e "ssh $SSH_OPTS" \
    "user@$ip:/opt/nc-backup/db/nextcloud-latest.dump" \
    "$dest/db/" \
    >> "$LOG" 2>&1

  # Sync Nextcloud config (config.php)
  rsync -avz \
    -e "ssh $SSH_OPTS" \
    "user@$ip:/var/lib/docker/volumes/nextcloud_aio_nextcloud/_data/config/" \
    "$dest/config/" \
    >> "$LOG" 2>&1

  echo "[$(date '+%F %T')] $instance sync complete" >> "$LOG"
}

# Run all syncs (sequentially to limit bandwidth)
for inst in nc1 nc2 nc3 nc4; do
  sync_instance "$inst"
done
```

### 7.3 Cron Schedule (Remote)

```bash
# Sync every 30 minutes (adjust based on bandwidth)
crontab -e
# Add:
*/30 * * * * /opt/nextcloud-standby/sync-files.sh
# Restore DBs 5 minutes after sync
5,35 * * * * /opt/nextcloud-standby/restore-db.sh 2>&1 | logger -t nc-restore
```

### 7.4 Bandwidth Limiting (Optional)

If the remote site has limited upload bandwidth:

```bash
# In rsync command, add --bwlimit (in KBps)
rsync -avz --delete --bwlimit=5000 ...  # limit to 5 MB/s
```

---

## 8. Phase 5 — Nextcloud Standby Instances

On the remote server, deploy 4 Nextcloud containers (non-AIO) that can be activated during failover.

### 8.1 Why Not AIO on Remote?

Nextcloud AIO's mastercontainer tightly manages its own stack (creates/recreates containers, manages certs, updates). Running a second AIO with the same data would:
- Conflict with the primary's update management
- Try to run migrations on the replicated DB
- Auto-start and accept traffic unintentionally

Instead, the remote runs **standard Nextcloud Docker images** in stopped/maintenance mode, ready to be brought online.

### 8.2 Docker Compose — Standby Nextcloud Stack

```yaml
# /opt/nextcloud-standby/docker-compose.yml
services:
  # ── NC1 Standby ──
  nc1:
    image: nextcloud:32-apache
    container_name: nc1-standby
    restart: "no"    # Stays stopped until failover
    ports:
      - "8081:80"
    environment:
      POSTGRES_HOST: db-nc1
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC1_DB_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "dpsg-bruenninghausen.de"
      REDIS_HOST: redis-nc1
      OVERWRITEPROTOCOL: https
    volumes:
      - /data/sync/nc1/files:/var/www/html/data
      - nc1_app:/var/www/html
    depends_on:
      - db-nc1
      - redis-nc1

  redis-nc1:
    image: redis:7-alpine
    container_name: nc1-redis-standby
    restart: "no"
    volumes:
      - nc1_redis:/data

  # ── NC2 Standby ──
  nc2:
    image: nextcloud:32-apache
    container_name: nc2-standby
    restart: "no"
    ports:
      - "8082:80"
    environment:
      POSTGRES_HOST: db-nc2
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC2_DB_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "cloud.wueblu.com"
      REDIS_HOST: redis-nc2
      OVERWRITEPROTOCOL: https
    volumes:
      - /data/sync/nc2/files:/var/www/html/data
      - nc2_app:/var/www/html
    depends_on:
      - db-nc2
      - redis-nc2

  redis-nc2:
    image: redis:7-alpine
    container_name: nc2-redis-standby
    restart: "no"
    volumes:
      - nc2_redis:/data

  # ── NC3 Standby ──
  nc3:
    image: nextcloud:32-apache
    container_name: nc3-standby
    restart: "no"
    ports:
      - "8083:80"
    environment:
      POSTGRES_HOST: db-nc3
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC3_DB_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "test.dpsg-bruenninghausen.de"
      REDIS_HOST: redis-nc3
      OVERWRITEPROTOCOL: https
    volumes:
      - /data/sync/nc3/files:/var/www/html/data
      - nc3_app:/var/www/html
    depends_on:
      - db-nc3
      - redis-nc3

  redis-nc3:
    image: redis:7-alpine
    container_name: nc3-redis-standby
    restart: "no"
    volumes:
      - nc3_redis:/data

  # ── NC4 Standby ──
  nc4:
    image: nextcloud:32-apache
    container_name: nc4-standby
    restart: "no"
    ports:
      - "8084:80"
    environment:
      POSTGRES_HOST: db-nc4
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC4_DB_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "vogt-cloud.de"
      REDIS_HOST: redis-nc4
      OVERWRITEPROTOCOL: https
    volumes:
      - /data/sync/nc4/files:/var/www/html/data
      - nc4_app:/var/www/html
    depends_on:
      - db-nc4
      - redis-nc4

  redis-nc4:
    image: redis:7-alpine
    container_name: nc4-redis-standby
    restart: "no"
    volumes:
      - nc4_redis:/data

volumes:
  nc1_app:
  nc1_redis:
  nc2_app:
  nc2_redis:
  nc3_app:
  nc3_redis:
  nc4_app:
  nc4_redis:
```

> **Important:** All containers have `restart: "no"` — they stay stopped during normal operation. Only the DB containers run continuously to receive restores.

### 8.3 Config.php Adjustments for Failover

During failover, the standby `config.php` needs modifications. Prepare a template:

```bash
# /opt/nextcloud-standby/failover-config.sh
#!/bin/bash
# Run inside the NC container after starting it during failover

# Disable AI integrations (not available at remote site)
php occ app:disable context_chat
php occ app:disable context_chat_backend
php occ app:disable integration_openai

# Update trusted domains if needed
php occ config:system:set trusted_domains 0 --value="$DOMAIN"

# Set maintenance mode off
php occ maintenance:mode --off
```

---

## 6. Phase 3 — Cloudflare Tunnel & DNS

Since the standby is IPv6-only, direct A-record failover won't work for IPv4 clients. **Cloudflare Tunnel** solves this elegantly.

### 6.1 Why Cloudflare Tunnel?

| Problem | Solution via Cloudflare Tunnel |
|---|---|
| Standby has no IPv4 | `cloudflared` makes **outbound** connection to CF edge — no inbound ports needed |
| IPv4-only clients can't reach standby | Cloudflare edge serves both IPv4 + IPv6 to clients, regardless of origin |
| No public IP needed | Tunnel works behind NAT, dynamic IPs, IPv6-only |
| TLS certificates | Cloudflare provides edge TLS automatically (+ origin certs) |
| No reverse proxy needed | Tunnel routes directly to local services — replaces NPM on standby |

### 6.2 Cloudflare Setup (One-Time)

#### 6.2.1 Move Domains to Cloudflare DNS

All 4 domains are currently at **Netcup** and must use Cloudflare as the authoritative DNS:

1. Create a free Cloudflare account
2. Add each domain zone: `dpsg-bruenninghausen.de`, `wueblu.com`, `vogt-cloud.de`
3. Cloudflare will show you two nameservers (e.g., `anna.ns.cloudflare.com`, `bob.ns.cloudflare.com`)
4. **Change NS records at Netcup:**
   - Log into Netcup CCP → *Domains* → select domain → *Nameserver*
   - Change from Netcup default NS to the Cloudflare nameservers
   - Repeat for all 3 domains
   - Propagation takes up to 24–48 hours (usually faster)
5. Set all records to **Proxied** (orange cloud) — this is key for the failover to work

> **Note:** The domains stay registered at Netcup — only DNS resolution moves to Cloudflare. No domain transfer needed.

#### 6.2.2 Normal Operation DNS Records (Orange-Clouded)

| Domain | Type | Value | Proxy | TTL |
|---|---|---|---|---|
| `dpsg-bruenninghausen.de` | A | `<primary-public-ipv4>` (dynamic) | ☁️ Proxied | Auto |
| `cloud.wueblu.com` | A | `<primary-public-ipv4>` (dynamic) | ☁️ Proxied | Auto |
| `test.dpsg-bruenninghausen.de` | A | `<primary-public-ipv4>` (dynamic) | ☁️ Proxied | Auto |
| `vogt-cloud.de` | A | `<primary-public-ipv4>` (dynamic) | ☁️ Proxied | Auto |
| `wg-primary.dpsg-bruenninghausen.de` | A/AAAA | `<primary-ip>` (dynamic) | ☀️ DNS-only | Auto |
| `wg-remote.dpsg-bruenninghausen.de` | AAAA | `<remote-ipv6>` (dynamic) | ☀️ DNS-only | Auto |

> With Cloudflare proxy enabled, TTL is managed by Cloudflare (effectively ~30s). This makes failover propagation near-instant.

> **Dynamic IP:** Since the primary has a dynamic IP, the proxied A records must be updated whenever the IP changes. See section 6.2.4.

#### 6.2.3 Create an API Token

Needed for the auto-failover daemon. Create a **Custom Token** with these permissions:

- **Zone → DNS → Edit** (for all 4 zones)
- **Account → Cloudflare Tunnel → Edit**
- **Zone → Zone → Read**

Store the token securely:

```bash
# /opt/nextcloud-standby/.env
CF_API_TOKEN=<your-api-token>
CF_ACCOUNT_ID=<your-account-id>
```

#### 6.2.4 Cloudflare DynDNS Updater (Primary Site)

Since the primary has a dynamic IP, the **proxied A records** for all 4 Nextcloud domains must track the current IP. Install this updater on the primary site:

```bash
# /opt/dyndns/cf-nc-dyndns.sh — run on primary site (e.g., VM 101 or pve)
#!/bin/bash
# Updates Cloudflare proxied A records for all NC domains when primary IP changes
set -euo pipefail

CF_TOKEN="<cloudflare-api-token>"
IP_CACHE="/tmp/cf-dyndns-last-ip"

# Get current public IPv4
CURRENT_IP=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
[[ -z "$CURRENT_IP" ]] && exit 0

# Skip if IP hasn't changed
if [[ -f "$IP_CACHE" ]] && [[ "$(cat $IP_CACHE)" == "$CURRENT_IP" ]]; then
  exit 0
fi

update_record() {
  local zone_id=$1 record_id=$2 name=$3
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"content\":\"$CURRENT_IP\",\"proxied\":true}" > /dev/null
  logger -t cf-dyndns "Updated $name → $CURRENT_IP"
}

# Update all NC domain A records
# Zone: dpsg-bruenninghausen.de
update_record "<zone-id-dpsg>" "<record-id>" "dpsg-bruenninghausen.de"
update_record "<zone-id-dpsg>" "<record-id>" "test.dpsg-bruenninghausen.de"
# Zone: wueblu.com
update_record "<zone-id-wueblu>" "<record-id>" "cloud.wueblu.com"
# Zone: vogt-cloud.de
update_record "<zone-id-vogt>" "<record-id>" "vogt-cloud.de"

echo "$CURRENT_IP" > "$IP_CACHE"
logger -t cf-dyndns "All NC domains updated to $CURRENT_IP"
```

```bash
chmod +x /opt/dyndns/cf-nc-dyndns.sh
# Run every 5 minutes on primary
echo '*/5 * * * * /opt/dyndns/cf-nc-dyndns.sh' | sudo tee /etc/cron.d/cf-nc-dyndns
```

> **Why separate from the WireGuard DynDNS?** The NC domain records are **proxied** (orange cloud) A records — they serve user traffic via Cloudflare. The WireGuard DynDNS records are **DNS-only** (grey cloud) — they carry raw UDP. Different records, different proxy settings.

### 6.3 Create Cloudflare Tunnel (on Remote)

```bash
# Authenticate cloudflared (one-time)
cloudflared tunnel login

# Create the tunnel
cloudflared tunnel create nc-standby

# This generates:
# - Tunnel ID (UUID)
# - Credentials file: ~/.cloudflared/<tunnel-id>.json
```

### 6.4 Tunnel Configuration

```yaml
# /etc/cloudflared/config.yml
tunnel: <tunnel-id>
credentials-file: /root/.cloudflared/<tunnel-id>.json

# These ingress rules are always configured but only matter when
# the tunnel is active (during failover)
ingress:
  - hostname: dpsg-bruenninghausen.de
    service: http://localhost:8081
  - hostname: cloud.wueblu.com
    service: http://localhost:8082
  - hostname: test.dpsg-bruenninghausen.de
    service: http://localhost:8083
  - hostname: vogt-cloud.de
    service: http://localhost:8084
  # Catch-all (required)
  - service: http_status:404
```

### 6.5 Install as Service (but keep stopped)

```bash
# Install the systemd service
sudo cloudflared service install

# Keep it STOPPED during normal operation — only starts during failover
sudo systemctl disable cloudflared
sudo systemctl stop cloudflared
```

### 6.6 Pre-Create DNS CNAME Records for Tunnel (Inactive)

The failover daemon will switch from A records (primary) to CNAME records (tunnel). Pre-create the CNAMEs but keep them disabled/inactive:

```bash
# The CNAME target for a Cloudflare Tunnel is:
# <tunnel-id>.cfargotunnel.com

# These will be created by the failover daemon via API
# No manual action needed — but document the tunnel ID
echo "Tunnel CNAME target: <tunnel-id>.cfargotunnel.com"
```

### 6.7 How Failover DNS Switch Works

```
NORMAL STATE:
  dpsg-bruenninghausen.de → A record → <primary-ipv4> (proxied)
  Cloudflare → forwards to primary via IPv4

FAILOVER STATE:
  dpsg-bruenninghausen.de → CNAME → <tunnel-id>.cfargotunnel.com (proxied)
  Cloudflare → routes through tunnel → cloudflared on standby → localhost:8081
```

The failover daemon automates this switch via the Cloudflare API.

---

## 10. Phase 7 — Automatic Failover Daemon

The core of the automatic failover: a Python daemon running on the standby server that continuously monitors the primary and triggers failover when it's confirmed down.

### 10.1 Architecture

```
nc-failover daemon (on standby)
  │
  ├── Health Checker
  │     ├── HTTPS probe → dpsg-bruenninghausen.de/status.php
  │     ├── HTTPS probe → cloud.wueblu.com/status.php
  │     ├── HTTPS probe → test.dpsg-bruenninghausen.de/status.php
  │     ├── HTTPS probe → vogt-cloud.de/status.php
  │     ├── WireGuard tunnel ping → 10.10.10.1
  │     └── External probe → via Cloudflare Workers (optional)
  │
  ├── Failure Detector
  │     ├── Requires 5 consecutive failures (configurable)
  │     ├── Over 5 minutes minimum (configurable)
  │     ├── Multiple probe types must fail (not just one)
  │     └── Cooldown: no re-trigger for 30 min after failover
  │
  ├── Failover Executor
  │     ├── 1. Stop sync cron jobs
  │     ├── 2. Restore latest DB dumps
  │     ├── 3. Start standby NC containers
  │     ├── 4. Disable AI apps via occ
  │     ├── 5. Start cloudflared tunnel
  │     ├── 6. Switch DNS (A → CNAME) via Cloudflare API
  │     └── 7. Send notification
  │
  └── State Machine
        ├── MONITORING → SUSPECT → CONFIRMING → FAILOVER → ACTIVE_STANDBY
        └── ACTIVE_STANDBY → (manual) → FAILBACK
```

### 10.2 Split-Brain Protection

**Critical:** The daemon must be very confident the primary is actually down before triggering failover. Running both sites simultaneously causes data divergence.

| Protection | Implementation |
|---|---|
| **Multi-probe confirmation** | Both HTTPS probes AND WireGuard ping must fail |
| **Time-based threshold** | At least 5 minutes of continuous failure |
| **Consecutive failures** | 5+ failed checks in a row (not just sporadic) |
| **External validation** | Optional: query an external service (e.g., `isitdown.site` API) to confirm it's not a local network issue |
| **Cooldown period** | After failover, no automatic failback for 30 min |
| **Manual failback only** | Automatic failover, but **never** automatic failback |
| **Lock file** | `/var/run/nc-failover.lock` prevents concurrent executions |

### 10.3 Failover Daemon Script

```python
#!/usr/bin/env python3
"""
nc-failover — Automatic failover daemon for Nextcloud standby.
Runs on the remote/standby server. Monitors primary, triggers failover.
"""

import os
import sys
import time
import json
import subprocess
import logging
import signal
import requests
from datetime import datetime, timedelta
from pathlib import Path
from enum import Enum

# ═══════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════

CONFIG = {
    # Health check targets (primary site)
    "probes": {
        "nc1": "https://dpsg-bruenninghausen.de/status.php",
        "nc2": "https://cloud.wueblu.com/status.php",
        "nc3": "https://test.dpsg-bruenninghausen.de/status.php",
        "nc4": "https://vogt-cloud.de/status.php",
    },
    "wireguard_ping_target": "10.10.10.1",

    # Failure detection thresholds
    "check_interval_seconds": 60,
    "consecutive_failures_required": 5,     # 5 failures = 5 min
    "min_probes_failed": 3,                 # at least 3 of 4 NC instances must be down
    "wireguard_must_fail": True,            # WG tunnel must also be down

    # Cooldown
    "failover_cooldown_minutes": 30,
    "probe_timeout_seconds": 10,

    # Cloudflare
    "cf_api_token": os.environ.get("CF_API_TOKEN", ""),
    "cf_tunnel_id": os.environ.get("CF_TUNNEL_ID", ""),

    # DynDNS hostname for primary site (resolved dynamically on failback)
    "primary_dyndns_hostname": os.environ.get("PRIMARY_DYNDNS", "homelab-primary.duckdns.org"),

    # DNS records to switch (zone_id → [{record_id, name}])
    # Populated from cf_dns_records.json
    "cf_dns_records_file": "/opt/nextcloud-standby/cf_dns_records.json",

    # Paths
    "lock_file": "/var/run/nc-failover.lock",
    "state_file": "/opt/nextcloud-standby/failover-state.json",
    "log_file": "/var/log/nc-failover.log",

    # Notification
    "ntfy_topic": os.environ.get("NTFY_TOPIC", ""),
    "ntfy_server": os.environ.get("NTFY_SERVER", "https://ntfy.sh"),
}


class State(Enum):
    MONITORING = "monitoring"
    SUSPECT = "suspect"
    CONFIRMING = "confirming"
    FAILOVER_IN_PROGRESS = "failover_in_progress"
    ACTIVE_STANDBY = "active_standby"


# ═══════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(CONFIG["log_file"]),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("nc-failover")


# ═══════════════════════════════════════════
# HEALTH CHECKS
# ═══════════════════════════════════════════

def check_https_probe(url: str) -> bool:
    """Returns True if the probe succeeds (primary is up)."""
    try:
        r = requests.get(url, timeout=CONFIG["probe_timeout_seconds"], verify=True)
        return r.status_code == 200
    except Exception:
        return False


def check_wireguard_ping() -> bool:
    """Returns True if WireGuard tunnel is up."""
    try:
        result = subprocess.run(
            ["ping", "-c", "2", "-W", "3", CONFIG["wireguard_ping_target"]],
            capture_output=True, timeout=10,
        )
        return result.returncode == 0
    except Exception:
        return False


def run_health_checks() -> dict:
    """Run all health checks. Returns dict of results."""
    results = {}
    for name, url in CONFIG["probes"].items():
        results[name] = check_https_probe(url)
    results["wireguard"] = check_wireguard_ping()
    return results


def evaluate_failure(results: dict) -> bool:
    """Returns True if the primary should be considered DOWN."""
    nc_failures = sum(1 for k, v in results.items() if k != "wireguard" and not v)
    wg_down = not results.get("wireguard", True)

    if nc_failures >= CONFIG["min_probes_failed"]:
        if CONFIG["wireguard_must_fail"] and not wg_down:
            log.info(f"NC probes failing ({nc_failures}) but WG tunnel is up — not failing over")
            return False
        return True
    return False


# ═══════════════════════════════════════════
# FAILOVER EXECUTION
# ═══════════════════════════════════════════

def execute_failover():
    """Run the full failover sequence."""
    log.warning("═══ EXECUTING AUTOMATIC FAILOVER ═══")

    # 1. Stop sync cron jobs
    log.info("Step 1/7: Stopping sync cron jobs")
    subprocess.run(
        "crontab -l 2>/dev/null | grep -v sync-files | grep -v restore-db | crontab -",
        shell=True,
    )

    # 2. Restore latest DB dumps
    log.info("Step 2/7: Restoring databases")
    subprocess.run(["/opt/nextcloud-standby/restore-db.sh"], timeout=300)

    # 3. Copy config files
    log.info("Step 3/7: Copying config.php files")
    for i in range(1, 5):
        subprocess.run([
            "docker", "cp",
            f"/data/sync/nc{i}/config/config.php",
            f"nc{i}-standby:/var/www/html/config/config.php",
        ])

    # 4. Start standby containers
    log.info("Step 4/7: Starting standby containers")
    subprocess.run(
        ["docker", "compose", "-f", "/opt/nextcloud-standby/docker-compose.yml",
         "up", "-d", "nc1", "nc2", "nc3", "nc4",
         "redis-nc1", "redis-nc2", "redis-nc3", "redis-nc4"],
        timeout=120,
    )
    time.sleep(30)

    # 5. Disable AI apps
    log.info("Step 5/7: Disabling AI apps on standby instances")
    for i in range(1, 5):
        for app in ["context_chat", "context_chat_backend", "integration_openai"]:
            subprocess.run(
                ["docker", "exec", "-u", "33", f"nc{i}-standby",
                 "php", "occ", "app:disable", app],
                capture_output=True,
            )
        subprocess.run(
            ["docker", "exec", "-u", "33", f"nc{i}-standby",
             "php", "occ", "maintenance:mode", "--off"],
        )

    # 6. Start Cloudflare Tunnel
    log.info("Step 6/7: Starting Cloudflare Tunnel")
    subprocess.run(["sudo", "systemctl", "start", "cloudflared"])

    # 7. Switch DNS from A records to Tunnel CNAMEs
    log.info("Step 7/7: Switching DNS to tunnel")
    switch_dns_to_tunnel()

    # Notify
    send_notification(
        "🔴 FAILOVER ACTIVATED",
        "Primary site unreachable. Standby is now serving traffic via Cloudflare Tunnel.",
    )
    log.warning("═══ FAILOVER COMPLETE — STANDBY IS ACTIVE ═══")


def switch_dns_to_tunnel():
    """Switch Cloudflare DNS from A records (primary) to CNAME (tunnel)."""
    tunnel_target = f"{CONFIG['cf_tunnel_id']}.cfargotunnel.com"
    headers = {
        "Authorization": f"Bearer {CONFIG['cf_api_token']}",
        "Content-Type": "application/json",
    }

    with open(CONFIG["cf_dns_records_file"]) as f:
        dns_records = json.load(f)

    for zone_id, records in dns_records.items():
        for rec in records:
            # Delete the A record
            requests.delete(
                f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{rec['record_id']}",
                headers=headers,
            )
            # Create CNAME pointing to tunnel
            requests.post(
                f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
                headers=headers,
                json={
                    "type": "CNAME",
                    "name": rec["name"],
                    "content": tunnel_target,
                    "proxied": True,
                    "ttl": 1,  # Auto TTL when proxied
                },
            )
            log.info(f"DNS switched: {rec['name']} → CNAME {tunnel_target}")


def switch_dns_to_primary():
    """Switch Cloudflare DNS back from CNAME (tunnel) to A records (primary).
    Resolves the primary's current IP dynamically via DynDNS hostname."""
    headers = {
        "Authorization": f"Bearer {CONFIG['cf_api_token']}",
        "Content-Type": "application/json",
    }

    # Resolve primary's current dynamic IP from DynDNS hostname
    import socket
    dyndns_host = CONFIG.get("primary_dyndns_hostname", "homelab-primary.duckdns.org")
    try:
        primary_ip = socket.getaddrinfo(dyndns_host, None, socket.AF_INET)[0][4][0]
        log.info(f"Resolved primary DynDNS {dyndns_host} → {primary_ip}")
    except Exception as e:
        log.error(f"Cannot resolve primary DynDNS hostname {dyndns_host}: {e}")
        log.error("Failback aborted — cannot determine primary IP")
        return

    with open(CONFIG["cf_dns_records_file"]) as f:
        dns_records = json.load(f)

    for zone_id, records in dns_records.items():
        # List current DNS records to find the CNAMEs we created
        resp = requests.get(
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
            headers=headers,
        )
        current = resp.json().get("result", [])

        for rec in records:
            # Delete CNAME if exists
            for cr in current:
                if cr["name"] == rec["name"] and cr["type"] == "CNAME":
                    requests.delete(
                        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{cr['id']}",
                        headers=headers,
                    )
            # Re-create A record with dynamically resolved IP
            resp = requests.post(
                f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
                headers=headers,
                json={
                    "type": "A",
                    "name": rec["name"],
                    "content": primary_ip,
                    "proxied": True,
                    "ttl": 1,
                },
            )
            new_id = resp.json().get("result", {}).get("id", "")
            rec["record_id"] = new_id
            log.info(f"DNS restored: {rec['name']} → A {primary_ip}")

    # Save updated record IDs
    with open(CONFIG["cf_dns_records_file"], "w") as f:
        json.dump(dns_records, f, indent=2)


# ═══════════════════════════════════════════
# NOTIFICATION
# ═══════════════════════════════════════════

def send_notification(title: str, message: str):
    """Send push notification via ntfy."""
    if not CONFIG["ntfy_topic"]:
        return
    try:
        requests.post(
            f"{CONFIG['ntfy_server']}/{CONFIG['ntfy_topic']}",
            data=message,
            headers={"Title": title, "Priority": "urgent", "Tags": "warning"},
            timeout=10,
        )
    except Exception as e:
        log.error(f"Failed to send notification: {e}")


# ═══════════════════════════════════════════
# STATE MANAGEMENT
# ═══════════════════════════════════════════

def load_state() -> dict:
    try:
        with open(CONFIG["state_file"]) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {
            "state": State.MONITORING.value,
            "consecutive_failures": 0,
            "first_failure_at": None,
            "last_failover_at": None,
        }


def save_state(state: dict):
    with open(CONFIG["state_file"], "w") as f:
        json.dump(state, f, indent=2)


# ═══════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════

def main():
    log.info("nc-failover daemon starting")

    state = load_state()

    # If already in ACTIVE_STANDBY, just keep running (wait for manual failback)
    if state["state"] == State.ACTIVE_STANDBY.value:
        log.info("Already in ACTIVE_STANDBY state — waiting for manual failback")
        while True:
            time.sleep(60)

    while True:
        try:
            results = run_health_checks()
            is_down = evaluate_failure(results)

            log.info(f"Health check: {results} → primary_down={is_down}")

            if is_down:
                state["consecutive_failures"] += 1
                if state["first_failure_at"] is None:
                    state["first_failure_at"] = datetime.utcnow().isoformat()

                log.warning(
                    f"Failure #{state['consecutive_failures']} "
                    f"(need {CONFIG['consecutive_failures_required']})"
                )

                # Check if we should send an early warning
                if state["consecutive_failures"] == 2:
                    send_notification(
                        "⚠️ Primary site issues",
                        f"Primary failing health checks ({state['consecutive_failures']} consecutive). "
                        f"Auto-failover in {CONFIG['consecutive_failures_required'] - state['consecutive_failures']} more failures.",
                    )

                # Check if threshold is reached
                if state["consecutive_failures"] >= CONFIG["consecutive_failures_required"]:
                    # Check cooldown
                    if state.get("last_failover_at"):
                        last = datetime.fromisoformat(state["last_failover_at"])
                        if datetime.utcnow() - last < timedelta(minutes=CONFIG["failover_cooldown_minutes"]):
                            log.warning("Failover cooldown active — not triggering")
                            continue

                    state["state"] = State.FAILOVER_IN_PROGRESS.value
                    save_state(state)
                    execute_failover()
                    state["state"] = State.ACTIVE_STANDBY.value
                    state["last_failover_at"] = datetime.utcnow().isoformat()
                    state["consecutive_failures"] = 0
                    state["first_failure_at"] = None
                    save_state(state)

                    # Stay in active standby mode
                    log.info("Entering ACTIVE_STANDBY mode — waiting for manual failback")
                    while True:
                        time.sleep(60)

            else:
                # Primary is up — reset failure counter
                if state["consecutive_failures"] > 0:
                    log.info("Primary recovered — resetting failure counter")
                state["consecutive_failures"] = 0
                state["first_failure_at"] = None
                state["state"] = State.MONITORING.value

            save_state(state)

        except Exception as e:
            log.error(f"Error in main loop: {e}", exc_info=True)

        time.sleep(CONFIG["check_interval_seconds"])


if __name__ == "__main__":
    main()
```

### 10.4 DNS Records Configuration File

```json
// /opt/nextcloud-standby/cf_dns_records.json
// Note: primary_ip is NOT stored here — it's resolved dynamically
// from the DynDNS hostname (PRIMARY_DYNDNS env var) during failback.
{
  "<zone-id-dpsg>": [
    {
      "record_id": "<record-id>",
      "name": "dpsg-bruenninghausen.de"
    },
    {
      "record_id": "<record-id>",
      "name": "test.dpsg-bruenninghausen.de"
    }
  ],
  "<zone-id-wueblu>": [
    {
      "record_id": "<record-id>",
      "name": "cloud.wueblu.com"
    }
  ],
  "<zone-id-vogt>": [
    {
      "record_id": "<record-id>",
      "name": "vogt-cloud.de"
    }
  ]
}
```

> **Find your record IDs:** `curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/<zone-id>/dns_records" | jq '.result[] | {id, name, type, content}'`

```bash
# /opt/nextcloud-standby/.env
CF_API_TOKEN=<your-api-token>
CF_ACCOUNT_ID=<your-account-id>
CF_TUNNEL_ID=<your-tunnel-id>
PRIMARY_DYNDNS=homelab-primary.duckdns.org
NTFY_TOPIC=<your-ntfy-topic>
NTFY_SERVER=https://ntfy.sh
```

### 10.5 Install as systemd Service

```ini
# /etc/systemd/system/nc-failover.service
[Unit]
Description=Nextcloud Automatic Failover Daemon
After=network-online.target wg-quick@wg-site.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/opt/nextcloud-standby/.env
ExecStart=/usr/bin/python3 /opt/nextcloud-standby/nc-failover.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nc-failover
```

### 10.6 Install Python Dependencies

```bash
sudo pip3 install requests
# Or use a venv:
python3 -m venv /opt/nextcloud-standby/venv
/opt/nextcloud-standby/venv/bin/pip install requests
# Update ExecStart in service to use venv python
```

---

## 11. Phase 8 — Monitoring & Alerting

### 11.1 Monitoring Stack on Remote

```yaml
# Add to /opt/nextcloud-standby/docker-compose.monitoring.yml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - uptime_kuma_data:/app/data

volumes:
  uptime_kuma_data:
```

Configure these monitors in Uptime Kuma:

| Monitor | Type | Target | Interval | Alert |
|---|---|---|---|---|
| NC1 primary | HTTPS | `dpsg-bruenninghausen.de/status.php` | 60s | ntfy |
| NC2 primary | HTTPS | `cloud.wueblu.com/status.php` | 60s | ntfy |
| NC3 primary | HTTPS | `test.dpsg-bruenninghausen.de/status.php` | 60s | ntfy |
| NC4 primary | HTTPS | `vogt-cloud.de/status.php` | 60s | ntfy |
| WireGuard tunnel | Ping | `10.10.10.1` | 30s | ntfy |
| Failover daemon | Docker | `nc-failover` service | 60s | ntfy |
| Sync freshness | Script | `/opt/nextcloud-standby/check-sync-age.sh` | 300s | ntfy |

### 11.2 Sync Freshness Monitoring

```bash
# /opt/nextcloud-standby/check-sync-age.sh
#!/bin/bash
MAX_AGE_MIN=60  # Alert if last sync > 60 minutes old

for inst in nc1 nc2 nc3 nc4; do
  dump="/data/sync/$inst/db/nextcloud-latest.dump"
  if [[ -f "$dump" ]]; then
    age_min=$(( ($(date +%s) - $(stat -c %Y "$dump")) / 60 ))
    if [[ $age_min -gt $MAX_AGE_MIN ]]; then
      echo "WARNING: $inst DB dump is ${age_min}m old (threshold: ${MAX_AGE_MIN}m)"
      curl -s -d "NC backup $inst is ${age_min}m stale" ntfy.sh/your-topic
    fi
  else
    echo "ERROR: $inst DB dump not found"
    curl -s -d "NC backup $inst dump missing!" ntfy.sh/your-topic
  fi
done
```

### 11.3 Failover State Dashboard

The failover daemon writes its state to `/opt/nextcloud-standby/failover-state.json`. Check it anytime:

```bash
cat /opt/nextcloud-standby/failover-state.json | python3 -m json.tool
# Shows: state, consecutive_failures, last_failover_at

# View live daemon logs
journalctl -u nc-failover -f
```

---

## 12. Phase 9 — Failover Procedure (Automated)

### How Automatic Failover Works

```
Timeline:
  T+0:00  Primary goes down
  T+0:01  Failover daemon: health check fails (1/5)
  T+0:02  Failover daemon: health check fails (2/5), early warning notification sent
  T+0:03  Failover daemon: health check fails (3/5)
  T+0:04  Failover daemon: health check fails (4/5)
  T+0:05  Failover daemon: health check fails (5/5) → THRESHOLD REACHED
  T+0:05  Failover daemon: stops sync cron jobs
  T+0:06  Failover daemon: restores latest DB dumps
  T+0:06  Failover daemon: starts standby NC containers
  T+0:07  Failover daemon: disables AI apps
  T+0:07  Failover daemon: starts cloudflared tunnel
  T+0:07  Failover daemon: switches DNS (A → CNAME to tunnel)
  T+0:08  Cloudflare propagation (~30s with proxied records)
  T+0:08  Users start reaching standby via Cloudflare Tunnel
  T+0:08  Push notification: "FAILOVER ACTIVATED"
```

### Expected Downtime (Automated)

| Phase | Duration |
|---|---|
| Detection (5 consecutive failures) | ~5 min |
| Failover execution (automated) | ~2–3 min |
| DNS/tunnel propagation (Cloudflare proxied) | ~30 sec |
| **Total** | **~7–8 min** |

Compare: manual failover was 20–50 min.

### What Users Lose During Failover

| Feature | Status |
|---|---|
| File access, sharing, sync clients | ✅ Available |
| Calendar, Contacts, Mail | ✅ Available |
| Talk (calls/chat) | ✅ Available (TURN/STUN may need adjustment) |
| AI Assistant / Context Chat | ❌ Disabled (no GPU at remote) |
| Integration OpenAI (LLM) | ❌ Disabled |
| Recent changes (< 30 min) | ⚠️ Potentially lost (RPO ≈ 30 min) |

### Manual Failover Override

If the daemon hasn't triggered but you want to force failover:

```bash
# Trigger immediate failover
sudo /opt/nextcloud-standby/nc-failover.py --force-failover

# Or run the steps manually:
sudo systemctl stop nc-failover   # stop the daemon
/opt/nextcloud-standby/restore-db.sh
docker compose -f /opt/nextcloud-standby/docker-compose.yml up -d
sudo systemctl start cloudflared
# DNS switch happens via the daemon — or call the function directly
```

---

## 13. Phase 10 — Failback Procedure (Manual)

> **Failback is always MANUAL.** Automatic failback risks split-brain (both sites active simultaneously, causing data divergence). A human must verify the primary is stable before switching back.

After the primary site is restored:

```bash
# ═══════════════════════════════════════════
# FAILBACK RUNBOOK — Execute step by step
# ═══════════════════════════════════════════

# 1. Verify primary is actually stable (not just a brief recovery)
#    Wait at least 15 minutes after primary comes back online
ping -c 10 10.10.10.1   # WireGuard tunnel
curl -s https://dpsg-bruenninghausen.de/status.php  # via internet (still hits standby)

# 2. Put standby NC instances in maintenance mode
for i in 1 2 3 4; do
  docker exec -u 33 "nc$i-standby" php occ maintenance:mode --on
done

# 3. Dump standby databases (capture any changes made during failover)
mkdir -p /data/failback
for i in 1 2 3 4; do
  port=$((i * 10000 + 5432))
  pg_dump -h 127.0.0.1 -p "$port" -U nextcloud -Fc nextcloud \
    > "/data/failback/nc$i-failback.dump"
done

# 4. Rsync changed files from standby back to primary
for i in 1 2 3 4; do
  ip="192.168.1.12$i"
  rsync -avz --delete \
    "/data/sync/nc$i/files/" \
    "nc-sync@$ip:/var/lib/docker/volumes/nextcloud_aio_nextcloud_data/_data/"
done

# 5. Restore database dumps on primary
for i in 1 2 3 4; do
  ip="192.168.1.12$i"
  scp "/data/failback/nc$i-failback.dump" "nc-sync@$ip:/tmp/"
  ssh "nc-sync@$ip" "docker exec -i nextcloud-aio-database pg_restore \
    -U nextcloud -d nextcloud --clean --if-exists /tmp/nc$i-failback.dump"
done

# 6. Start primary AIO instances
# (Done via AIO mastercontainer or manually on each VM)

# 7. Switch DNS back to primary (CNAME → A record)
#    The failover daemon has a switch_dns_to_primary() function
python3 -c "
import sys; sys.path.insert(0, '/opt/nextcloud-standby')
from nc_failover import switch_dns_to_primary, CONFIG
CONFIG['cf_api_token'] = '$(cat /opt/nextcloud-standby/.env | grep CF_API_TOKEN | cut -d= -f2)'
switch_dns_to_primary()
"

# 8. Stop Cloudflare Tunnel
sudo systemctl stop cloudflared

# 9. Stop standby containers
cd /opt/nextcloud-standby
docker compose down

# 10. Reset failover daemon state
echo '{"state":"monitoring","consecutive_failures":0,"first_failure_at":null,"last_failover_at":null}' \
  > /opt/nextcloud-standby/failover-state.json
sudo systemctl restart nc-failover

# 11. Re-enable sync cron jobs
(crontab -l 2>/dev/null; echo "*/30 * * * * /opt/nextcloud-standby/sync-files.sh") | crontab -
(crontab -l 2>/dev/null; echo "5,35 * * * * /opt/nextcloud-standby/restore-db.sh 2>&1 | logger -t nc-restore") | crontab -

# 12. Re-enable AI apps on primary NC instances
for i in 1 2 3 4; do
  ip="192.168.1.12$i"
  ssh "nc-sync@$ip" "docker exec -u 33 nextcloud-aio-nextcloud php occ app:enable integration_openai"
  ssh "nc-sync@$ip" "docker exec -u 33 nextcloud-aio-nextcloud php occ app:enable context_chat"
done
```

---

## 14. Changes Required at the Primary Site

### Summary of All Changes Needed on Primary

| Change | Where | Why |
|---|---|---|
| **Move DNS to Cloudflare** | All 4 domains | Required for Tunnel-based failover + proxied records |
| **Enable Cloudflare proxy (orange cloud)** | CF dashboard | Hides origin, enables instant DNS switching |
| **Install CF DynDNS updater** | VM 101 / pve | Primary has dynamic IP — keeps proxied A records in sync |
| **Set up DynDNS for WireGuard** | VM 101 | Dynamic IP — WireGuard endpoint needs stable hostname |
| **Install WireGuard reresolve cron** | VM 101 | Re-resolve peer DynDNS every 2 min for IP changes |
| **Add WireGuard site-to-site peer** | VM 101 (WireGuard) | Tunnel to remote site using DynDNS hostname |
| **Enable IPv6 on WireGuard host** | VM 101 / router | Remote is IPv6-only, needs IPv6 WireGuard endpoint |
| **Install pg_dump cron** | VMs 121–124 (each NC) | Export DB for replication |
| **Create backup directory** | VMs 121–124 | Store DB dumps |
| **Allow SSH from remote** | VMs 121–124 | rsync file sync |
| **Create sync user** | VMs 121–124 | Dedicated low-privilege user for rsync |
| **Firewall rules** | VM 101 / router | Allow tunnel traffic to NC VMs |
| **Port forwarding (WireGuard)** | Router | Forward UDP 51821 to VM 101 |
| **Document AIO DB passwords** | Docs / vault | Needed for standby PostgreSQL |

### Detailed: Per NC VM Changes

```bash
# ═══════════════════════════════════════════
# Run on each NC VM (121, 122, 123, 124)
# ═══════════════════════════════════════════

# 1. Create sync user with limited access
sudo useradd -m -s /bin/bash nc-sync
sudo mkdir -p /home/nc-sync/.ssh
# Paste the remote server's public key
echo "<remote-sync-public-key>" | sudo tee /home/nc-sync/.ssh/authorized_keys
sudo chmod 700 /home/nc-sync/.ssh
sudo chmod 600 /home/nc-sync/.ssh/authorized_keys
sudo chown -R nc-sync:nc-sync /home/nc-sync/.ssh

# 2. Grant sync user read access to Docker volumes
sudo usermod -aG docker nc-sync

# 3. Create backup directory
sudo mkdir -p /opt/nc-backup/db
sudo chown -R nc-sync:nc-sync /opt/nc-backup

# 4. Install the DB backup cron (as root, runs docker)
sudo cp backup-db.sh /opt/nc-backup/
sudo chmod +x /opt/nc-backup/backup-db.sh
echo '*/15 * * * * /opt/nc-backup/backup-db.sh 2>&1 | logger -t nc-backup' \
  | sudo crontab -

# 5. Document the AIO PostgreSQL password
# Find it in the AIO mastercontainer:
docker inspect nextcloud-aio-database | grep POSTGRES_PASSWORD
# → Store this securely — needed for standby DB setup
```

### Detailed: DNS Changes

**Do this FIRST — before anything else:**

All domains are registered at **Netcup**. Only the nameservers change — no domain transfer needed.

1. Create a free Cloudflare account
2. Add all domain zones to Cloudflare:
   - `dpsg-bruenninghausen.de`
   - `wueblu.com` (for `cloud.wueblu.com`)
   - `vogt-cloud.de`
3. **Change NS records at Netcup CCP** (for each domain):
   - Log into [Netcup CCP](https://www.customercontrolpanel.de)
   - Go to *Domains* → select domain → *Nameserver*
   - Replace Netcup nameservers with the two Cloudflare NS values
   - Example: `anna.ns.cloudflare.com` + `bob.ns.cloudflare.com`
   - Repeat for all 3 domain zones
4. Wait for propagation (check via `dig NS dpsg-bruenninghausen.de`)
5. Set all A records to **Proxied** (orange cloud ☁️) in Cloudflare dashboard
6. Create **DNS-only** (grey cloud) records for WireGuard:
   - `wg-primary.dpsg-bruenninghausen.de` → A / AAAA (DNS-only)
   - `wg-remote.dpsg-bruenninghausen.de` → AAAA (DNS-only)
7. Verify domains are active in Cloudflare dashboard
8. Create an API token with DNS edit + Tunnel edit permissions
9. Deploy the CF DynDNS updater cron on the primary (see Phase 3, section 6.2.4)

On VM 101 (`192.168.1.101`):

```bash
# Ensure VM 101 has IPv6 connectivity
ip -6 addr show  # should show a global IPv6 address
ping6 -c 3 google.com  # verify IPv6 internet access

# If no IPv6: enable it on the Proxmox bridge (vmbr0)
# Edit /etc/network/interfaces on pve host, add IPv6 to the bridge
# Or: assign an IPv6 address to VM 101 via SLAAC/DHCPv6

# Generate keys for the site-to-site tunnel
wg genkey | tee /etc/wireguard/site-private.key | wg pubkey > /etc/wireguard/site-public.key
chmod 600 /etc/wireguard/site-private.key

# Create the site-to-site interface config
# See Phase 1 for full config (Section 4.2)
# Note: Endpoint uses DynDNS hostname, NOT a raw IP address
sudo systemctl enable --now wg-quick@wg-site

# Install the WireGuard reresolve-dns cron (see Section 4.0.1)
sudo cp /opt/wireguard/reresolve-dns.sh /opt/wireguard/
chmod +x /opt/wireguard/reresolve-dns.sh
echo '*/2 * * * * /opt/wireguard/reresolve-dns.sh 2>/dev/null' | sudo tee /etc/cron.d/wg-reresolve

# Install the DynDNS updater for WireGuard endpoint (see Section 4.0)
# AND the CF DynDNS updater for NC domain A records (see Section 6.2.4)

# Port forwarding: forward UDP 51821 to VM 101 on the router
# This must work over IPv6 if the remote is IPv6-only
```

---

## Appendix A — Decision: AIO vs. Manual Nextcloud

| Aspect | AIO on Standby | Manual NC on Standby (chosen) |
|---|---|---|
| Setup complexity | Higher (AIO fights you) | Moderate |
| Config management | AIO overwrites compose | Full control |
| Update alignment | Must match primary AIO version | Must match NC image version |
| Maintenance mode | Can accidentally auto-start | `restart: "no"` ensures cold standby |
| Data compatibility | Native (same container layout) | Needs volume mapping |
| Failover speed | Slower (AIO init sequence) | Faster (just `docker compose up`) |

**Verdict:** Manual Nextcloud Docker on standby is more predictable and doesn't fight AIO's automation.

---

## Appendix B — IPv6-Only: Why Cloudflare Tunnel

### The Problem

The standby server only has IPv6. Many clients (especially mobile networks, older ISPs, corporate networks) are still IPv4-only or have limited IPv6 support. A direct AAAA record would leave these clients unable to reach the standby during failover.

### Options Considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Direct AAAA records** | Simple, no middleman | IPv4-only clients can't connect | ❌ |
| **NAT64/DNS64 at remote** | Transparent to clients | Complex, requires infrastructure | ❌ |
| **4in6 tunnel (Hurricane Electric)** | Gives IPv4 to server | Adds latency, another dependency | ❌ |
| **Cloudflare Proxy (orange cloud)** | CF provides IPv4+IPv6 edge | Origin needs to accept CF connections | ✅ Partial |
| **Cloudflare Tunnel** | No inbound ports, works behind NAT, CF provides IPv4+IPv6, handles TLS | Depends on Cloudflare | ✅ **Chosen** |

### Why Cloudflare Tunnel Wins

1. **No public IP needed** — `cloudflared` makes outbound HTTPS connections to CF edge
2. **IPv4+IPv6 to all clients** — Cloudflare's anycast network serves both protocols
3. **No firewall/port-forwarding** — works behind NAT, CG-NAT, IPv6-only
4. **Built-in TLS** — Cloudflare edge certificate + origin certificate, no certbot needed
5. **No reverse proxy needed** — `cloudflared` routes directly to local ports, replaces NPM
6. **Fast DNS switching** — proxied records propagate in ~30 seconds (vs 5+ min for TTL-based)
7. **Free tier** — Cloudflare Tunnel is free for any number of tunnels

---

## Appendix C — Bandwidth Estimation

### Initial Sync

| NC Instance | Est. Data Size | Transfer Time @ 50 Mbit/s |
|---|---|---|
| NC1 (DPSG) | ~50 GB (est.) | ~2.5 hours |
| NC2 (Wueblu) | ~20 GB (est.) | ~1 hour |
| NC3 (Test) | ~5 GB (est.) | ~15 min |
| NC4 (Vogt) | ~30 GB (est.) | ~1.5 hours |
| **Total** | **~105 GB** | **~5.5 hours** |

> Adjust these estimates based on actual `du -sh` of your Nextcloud data volumes.

### Ongoing Sync (Incremental)

| Metric | Value |
|---|---|
| DB dump size (compressed, per instance) | ~50–200 MB |
| Typical daily file changes | ~500 MB–2 GB across all instances |
| Sync frequency | Every 30 minutes |
| Per-sync bandwidth | ~50–200 MB (rsync delta) |
| Daily total | ~2–4 GB |

---

## Appendix D — Replication Topology Diagram

```
PRIMARY NC VM (e.g., 192.168.1.121)
┌────────────────────────────────────────┐
│  nextcloud-aio-nextcloud               │
│    ├── /var/www/html/data  ─────────rsync──────┐
│    └── /var/www/html/config ────────rsync──────┐│
│  nextcloud-aio-database                │       ││
│    └── pg_dump (cron, */15) ─────────rsync─────┤│
└────────────────────────────────────────┘       ││
            │                                    ││
        WireGuard Tunnel (10.10.10.0/24)         ││
        Transport: IPv6                          ││
            │                                    ││
┌────────────────────────────────────────┐       ││
│  REMOTE SERVER (IPv6-only)             │       ││
│                                        │       ││
│  /data/sync/nc1/                       │       ││
│    ├── files/    ◄─────────────────────────────┘│
│    ├── config/   ◄──────────────────────────────┘
│    └── db/nextcloud-latest.dump ◄──────┘
│           │
│    pg_restore (cron) ──► db-nc1 (PostgreSQL)
│                                        │
│  nc1-standby (stopped)                 │
│    ├── /var/www/html/data → files/     │
│    └── connects to db-nc1              │
│                                        │
│  nc-failover daemon                    │
│    └── monitors primary                │
│    └── auto-starts containers          │
│    └── starts cloudflared              │
│    └── switches DNS (A → CNAME)        │
│                                        │
│  cloudflared (stopped until failover)  │
│    └── outbound tunnel → CF edge       │
│    └── routes: domain → localhost:808X │
└────────────────────────────────────────┘
```

---

## Implementation Priority

| Priority | Task | Effort | Risk if Skipped |
|---|---|---|---|
| 🔴 1 | Move all domains to Cloudflare DNS (proxied) | 1–2 hours | No failover mechanism at all |
| 🔴 2 | Set up DB dump cron on all NC VMs | 30 min | No DB replication |
| 🔴 3 | Create Cloudflare API token | 10 min | Daemon can't switch DNS |
| 🟡 4 | Provision remote server + OS | 1–2 hours | No redundancy |
| 🟡 5 | WireGuard site-to-site tunnel (IPv6 transport) | 1–2 hours | No secure replication path |
| 🟡 6 | Install cloudflared + create tunnel | 30 min | No way to serve traffic from standby |
| 🟡 7 | rsync file sync setup | 1 hour | No file replication |
| 🟢 8 | Deploy standby NC + DB containers | 2 hours | Can't failover |
| 🟢 9 | Deploy failover daemon | 1 hour | No automatic failover |
| 🟢 10 | Monitoring (Uptime Kuma) | 30 min | No visibility into system health |
| 🟢 11 | Test full failover drill | 2 hours | Untested = broken |

**Total estimated effort: ~12–15 hours**

---

## RPO / RTO Summary

| Metric | Value | Notes |
|---|---|---|
| **RPO** (Recovery Point Objective) | ≈ 30 minutes | Data loss window = sync interval |
| **RTO** (Recovery Time Objective) | ≈ 7–8 minutes | Auto-detection (5 min) + execution (2–3 min) + CF propagation (30s) |
| **Sync frequency** | DB: 15 min, files: 30 min | Adjustable based on bandwidth |
| **Failover trigger** | Automatic | 5 consecutive failures over 5 minutes |
| **Failback** | Manual only | Human verifies primary before switching back |
| **IPv4 client support** | ✅ Via Cloudflare Tunnel | Clients always reach CF's IPv4+IPv6 anycast |
| **AI features during failover** | Unavailable | GPU stays at primary only |
