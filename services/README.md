# Services

Overview of all services running in the home lab.

## Networking & Infrastructure

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| Nginx Proxy Manager | CT 200 | 192.168.1.200 | 80/443, 81 (admin) | Reverse proxy & SSL termination |
| AdGuard Home | CT 204 | 192.168.1.204 | 53 (DNS), 3000 (web) | DNS ad blocking |
| WireGuard | VM 101 | 192.168.1.101 | 51820/udp | VPN access |

## Reverse Proxy Routes (Nginx Proxy Manager)

| Domain | Backend | Scheme | Service |
|--------|---------|--------|---------|
| cloud.wueblu.com, cloud.wueblu.de | 192.168.1.122 (VM 122) | http | Nextcloud (Wueblu) |
| plex.wueblu.com, plex.wueblu.de | 192.168.1.203 (CT 203) | http | Plex |
| pve.wueblu.com, pve.wueblu.de | 192.168.1.199 (pve) | https | Proxmox Web UI |
| cloud.dpsg-bruenninghausen.de | 192.168.1.121 (VM 121) | http | Nextcloud (DPSG) |
| survey.dpsg-bruenninghausen.de | 192.168.1.211 (CT 211) | http | LimeSurvey |
| events.dpsg-bruenninghausen.de | 192.168.1.210 (CT 210) | http | Pretix |
| sab.wueblu.com, sab.wueblu.de | 192.168.1.206 (CT 206) | http | SABnzbd |
| vogt-cloud.de | 192.168.1.124 (VM 124) | http | Nextcloud (Vogt) |
| cctv.wueblu.com, cctv.wueblu.de | 192.168.1.103 (VM 103) | https | CCTV |
| survey.vogt-cloud.de | 192.168.1.213 (CT 213) | http | LimeSurvey (Vogt) |
| test.dpsg-bruenninghausen.de | 192.168.1.123:8780 (VM 123) | http | Nextcloud (test) |
| ai.wueblu.com | 192.168.1.202 | http | *Stale — not in use* |
| home.wueblu.com | 192.168.1.208 | http | *Stale — not in use* |

### Domains

- **wueblu.com** / **wueblu.de** — personal services
- **dpsg-bruenninghausen.de** — DPSG organization
- **vogt-cloud.de** — Vogt cloud services

## Home Automation

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| Home Assistant | VM 104 | 192.168.1.20 | 8123 | Home automation hub |
| OpenCCU | VM 105 | 192.168.1.21 | 80 | HomeMatic CCU (smart home devices) |

## Media & Downloads

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| Mediastack | VM 110 | 192.168.1.110 | — | Consolidated media VM (Docker) |

**Mediastack** consolidates former separate containers (Plex CT 203, data CT 201, SABnzbd CT 206) into a single Docker-based VM. Services include:

- **Plex** — Media server (plex.wueblu.com)
- **SABnzbd** — Usenet downloader (sab.wueblu.com)
- **Data services** — from CT 201
- NFS mount from SERVER-OMV `/export/mediastack`

> **Migration status:** Legacy containers (CT 201, CT 203, CT 206) are still running. TODO: document migration plan and decommission timeline.

## Cloud & Collaboration

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|--------|
| Nextcloud (DPSG) | VM 121 | 192.168.1.121 | 443 | File sync & collaboration (DPSG) |
| Nextcloud (Wueblu) | VM 122 | 192.168.1.122 | 443 | File sync & collaboration (Wueblu) |
| Nextcloud (Test) | VM 123 | 192.168.1.123 | 8780 | Test instance for DPSG (test.dpsg-bruenninghausen.de) |
| Nextcloud (Vogt) | VM 124 | 192.168.1.124 | 443 | File sync & collaboration (Vogt) |

## Business & Events

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| Pretix | CT 210 | 192.168.1.210 | 443 | Event ticketing |
| LimeSurvey | CT 211 | 192.168.1.211 | 443 | Online surveys |
| Dolibarr (DPSG) | CT 212 | — | 80 | ERP/CRM (stopped) |
| LimeSurvey (Vogt) | CT 213 | — | 443 | Online surveys (stopped) |

## AI & Compute

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| AI Platform | VM 120 | 192.168.1.120 | — | Nextcloud AI backend (GTX 1070 passthrough) |

> **Status:** In development. See [ai_plattform/nextcloud-ai-platform-homelab-plan.md](ai_plattform/nextcloud-ai-platform-homelab-plan.md) for full deployment plan. Accessible at ai.wueblu.com.

**Planned Docker services on VM 120:**

| Service | Port | Shared/Isolated | Purpose |
|---------|------|----------------|---------|
| Ollama | 11434 | Shared ×1 | LLM backend (llama3.1:8b) |
| LocalAI (Whisper) | 8300 | Shared ×1 | Speech-to-text |
| Context Chat Backend (NC1–4) | 10034–10037 | Isolated ×4 | Per-instance document Q&A |

**Consumers:** All 4 Nextcloud instances (DPSG, Wueblu, Test, Vogt) via `integration_openai` + AppAPI.

**VRAM budget (8 GiB GTX 1070):**
- Ollama (llama3.1:8b): ~5–6 GiB
- 4× CCB embedding servers: ~2–3 GiB each — **use shared embedding server** (Phase 9) to fit within 8 GiB

## Surveillance

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| CCTV | VM 103 | 192.168.1.103 | — | Camera surveillance |

## Gaming

| Service | Host | IP | Default Port | Purpose |
|---------|------|----|-------------|---------|
| Minecraft (DPSG) | CT 214 | 192.168.1.214 | 25565 | Minecraft server |
| Minecraft | CT 207 | — | 25565 | Minecraft server (stopped) |

## Other

| Service | Host | IP | Purpose |
|---------|------|----|---------|
| Data | CT 201 | 192.168.1.201 | Data services (TBD) |

## NFS Shares (SERVER-OMV → LAN)

| Export | Source | Allowed Clients | Purpose |
|--------|--------|----------------|---------|
| /export/media | SERVER-OMV | 192.168.0.0/23 | Media files for Plex |
| /export/mediastack | SERVER-OMV | 192.168.1.110 | Media management (Mediastack VM) |
| /export/test | SERVER-OMV | 192.168.0.0/23 | Test share |

## Service Access

Most services are likely accessed through Nginx Proxy Manager (CT 200) with domain names. Run the following on CT 200 to document proxy hosts:

```bash
# List NPM proxy hosts
cat /data/nginx/proxy_host/*.conf 2>/dev/null
# Or check the NPM API/database
```
