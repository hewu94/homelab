# Nextcloud AI Platform — Step-by-Step Setup Guide

> Based on actual deployment to the homelab on 2026-03-30.
> Tested with Nextcloud 32.0.6, CCB 5.3.0, Ollama, GTX 1070 8 GiB.

---

## Overview

| Component | Host | IP | Port |
|---|---|---|---|
| Ollama (shared LLM) | VM 120 (aiplatform) | 192.168.1.120 | 11434 |
| CCB for NC1 (DPSG) | VM 120 | 192.168.1.120 | 10034 |
| CCB for NC2 (Wueblu) | VM 120 | 192.168.1.120 | 10035 |
| CCB for NC3 (Test) | VM 120 | 192.168.1.120 | 10036 |
| CCB for NC4 (Vogt) | VM 120 | 192.168.1.120 | 10037 |
| NC1 (DPSG) | VM 121 | 192.168.1.121 | 443 |
| NC2 (Wueblu) | VM 122 | 192.168.1.122 | 443 |
| NC3 (Test) | VM 123 | 192.168.1.123 | 443 |
| NC4 (Vogt) | VM 124 | 192.168.1.124 | 443 |

---

## Phase 1 — Deploy Ollama on GPU VM

### 1.1 Verify GPU passthrough

```bash
ssh manager@192.168.1.120
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.2.2-runtime-ubuntu22.04 nvidia-smi
```

### 1.2 Start Ollama

```bash
cd ~/ai-plattform
docker compose up -d ollama
```

### 1.3 Pull a model

```bash
docker exec ollama ollama pull llama3.1:8b
```

### 1.4 Verify Ollama

```bash
curl http://localhost:11434/api/tags
```

Expected: JSON listing `llama3.1:8b`.

---

## Phase 2 — Deploy Context Chat Backend (per NC instance)

### 2.1 Create the .env file

For each Nextcloud instance, create `env/ncX.env`. Example for NC3:

```dotenv
AA_VERSION=3.0.0
APP_ID=context_chat_backend
APP_DISPLAY_NAME=Context Chat Backend
APP_VERSION=5.3.0
APP_HOST=0.0.0.0
APP_PORT=10034
APP_SECRET=<generate-unique-secret>
APP_PERSISTENT_STORAGE=/nc_app_context_chat_backend_data
NEXTCLOUD_URL=https://test.dpsg-bruenninghausen.de
NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES=compute
CUDA_VISIBLE_DEVICES=0
```

Generate a unique secret:

```bash
openssl rand -hex 32
```

**Critical:** `NEXTCLOUD_URL` must be the actual HTTPS URL of the target Nextcloud instance. The CCB calls back to this URL.

### 2.2 Start the CCB container

```bash
cd ~/ai-plattform
docker compose up -d context-chat-nc3
```

First start downloads the embedding model (`multilingual-e5-large-instruct`) from HuggingFace — takes 2-5 minutes.

### 2.3 Monitor startup

```bash
docker logs -f nc_app_context_chat_backend_nc3
```

Wait until you see:

```
INFO:     Uvicorn running on http://localhost:5000 (Press CTRL+C to quit)
```

This means the embedding server is ready.

### 2.4 Verify the CCB

```bash
curl http://localhost:10036/enabled
```

Should return a 200 response.

---

## Phase 3 — Install Nextcloud Apps (order matters!)

SSH into the Nextcloud VM and run these **in order**:

```bash
ssh dpsg@192.168.1.123
```

### 3.1 Install AppAPI

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install app_api
```

### 3.2 Install integration_openai

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install integration_openai
```

### 3.3 Install Context Chat (PHP app)

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install context_chat
```

### 3.4 Install Assistant

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install assistant
```

---

## Phase 4 — Configure integration_openai (Ollama)

In the Nextcloud web UI:

1. Go to **Administration Settings → Artificial Intelligence → OpenAI and LocalAI integration**
2. Set:
   - **Service URL**: `http://192.168.1.120:11434`
   - Check **Use Ollama-specific features**
   - **Default completion model**: `llama3.1:8b`
3. Save

This provides the Text2Text task provider that Context Chat uses for LLM queries.

---

## Phase 5 — Register CCB via AppAPI

### 5.1 Register a manual deploy daemon

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app_api:daemon:register \
  --net host \
  manual_install "Manual Install" manual-install \
  http 192.168.1.120 https://test.dpsg-bruenninghausen.de
```

### 5.2 Register the Context Chat Backend

**The secret must match `APP_SECRET` in the .env file!**

For NC3 (port 10036):

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app_api:app:register \
  context_chat_backend manual_install \
  --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"9d937bc18eeb4ec4b54ff58b47cfb43cc1115697bfce48958af464950dfe4a66\",\"port\":10036,\"scopes\":[],\"system_app\":0}" \
  --force-scopes --wait-finish
```

### 5.3 Verify registration

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app_api:app:list
```

Should show `context_chat_backend` as enabled.

### Troubleshooting: Unregister and re-register

If the URL or secret was wrong:

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ app_api:app:unregister context_chat_backend --force
```

Then repeat step 5.2.

---

## Phase 6 — Trigger Initial File Indexing

Context Chat does **not** automatically index existing files. You must trigger a scan.

### 6.1 Scan files for all users

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan admin
```

Repeat for each user that should have their files indexed, or use `--all-users` if supported.

### 6.2 Process the indexing queue

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ background-job:worker -t 300
```

This runs background jobs for 5 minutes. During this time, files are sent to the CCB for embedding.

### 6.3 Monitor indexing from the CCB side

In another terminal on the GPU VM:

```bash
docker logs -f nc_app_context_chat_backend_nc3 2>&1 | grep -v countIndexedDocuments
```

You should see `/loadSources` PUT requests and `/v1/embeddings` POST calls as documents are processed.

### 6.4 Check indexing progress

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:stats
```

Repeat the background-job:worker command until "Files successfully sent to backend" matches "Total eligible files".

---

## Phase 7 — Set Up Persistent Cron

Without a cron job, new/changed files won't be indexed automatically.

### 7.1 Add a crontab entry on the Nextcloud host

```bash
crontab -e
```

Add:

```
*/5 * * * * docker exec -u 33 nextcloud-aio-nextcloud php -f /var/www/html/cron.php
```

### 7.2 Verify cron is working

After 5 minutes, check in Nextcloud under **Administration Settings → Basic settings**. The "Last job ran" timestamp should be recent.

---

## Phase 8 — Verify Everything Works

### 8.1 Test LLM via Assistant

1. Open Nextcloud in the browser
2. Click the Assistant icon (wand) in the top bar
3. Type a prompt like "Explain what Nextcloud is"
4. You should get a response from llama3.1:8b

### 8.2 Test Context Chat search

```bash
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:search admin "Nextcloud"
```

Should return matching documents.

### 8.3 Test Context Chat via Assistant

1. Open the Assistant
2. Select "Context Chat" as the task type
3. Ask a question about your files, e.g. "What does the Nextcloud Manual say about sharing?"
4. The response should reference your indexed documents

### 8.4 Check GPU usage

```bash
ssh manager@192.168.1.120
nvidia-smi
```

Expected VRAM usage:
- Ollama (llama3.1:8b): ~5.3 GiB
- Each CCB embedding server: ~322 MiB
- Total with 1 CCB: ~5.6 GiB / 8 GiB

---

## Port Reference (per NC instance)

| NC Instance | Domain | CCB Port | Secret (from .env) |
|---|---|---|---|
| NC1 (DPSG) | dpsg-bruenninghausen.de | 10034 | see env/nc1.env |
| NC2 (Wueblu) | wueblu.com | 10035 | see env/nc2.env |
| NC3 (Test) | test.dpsg-bruenninghausen.de | 10036 | see env/nc3.env |
| NC4 (Vogt) | vogt-cloud.de | 10037 | see env/nc4.env |

---

## Common Issues

### CCB shows "enabled" but no files are indexed
- Run `context_chat:scan <user>` to queue files
- Run `background-job:worker -t 300` to process the queue
- Background jobs must run as uid 33 (www-data), not root

### Wrong NEXTCLOUD_URL in .env
- CCB can't call back to Nextcloud for LLM requests
- Fix the URL in the .env, recreate the container, then unregister/re-register via `app_api:app:unregister` + `app_api:app:register`

### Cron jobs only process Deck/Notifications, never Context Chat
- The FileSystemListenerJob only fires for file change events
- You must trigger an initial scan with `context_chat:scan`
- Subsequent changes are picked up automatically if cron is running

### VRAM not enough to run all 4 CCBs
- Use `CC_EM_BASE_URL` in the .env for instances 2-4 to share a single embedding server
- This reduces per-instance VRAM from ~322 MiB to near zero for embedding
