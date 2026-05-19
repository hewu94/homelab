# Nextcloud AI Platform — Homelab Deployment Plan

> **Environment:** 1× Ubuntu VM on Proxmox with NVIDIA GPU passthrough + Docker, 4× Nextcloud AIO VMs  
> **Goal:** Shared AI assistant, speech-to-text, text-to-speech, and per-instance Context Chat  
> **Date:** 2026-03-30  
> **Validated against:** [`nextcloud/context_chat_backend`](https://github.com/nextcloud/context_chat_backend), [`nextcloud/integration_openai`](https://github.com/nextcloud/integration_openai), [`nextcloud/llm2`](https://github.com/nextcloud/llm2) source code and documentation

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 — GPU VM: Deploy Ollama (Shared LLM)](#3-phase-1--gpu-vm-deploy-ollama-shared-llm)
4. [Phase 2 — GPU VM: Deploy Whisper STT (Shared)](#4-phase-2--gpu-vm-deploy-whisper-stt-shared)
5. [Phase 3 — GPU VM: Deploy Context Chat Backend ×4 (Per-Instance)](#5-phase-3--gpu-vm-deploy-context-chat-backend-4-per-instance)
6. [Phase 4 — Nextcloud: Install Apps (Per Instance, In Order)](#6-phase-4--nextcloud-install-apps-per-instance-in-order)
7. [Phase 5 — Nextcloud: Configure integration_openai (Per Instance)](#7-phase-5--nextcloud-configure-integration_openai-per-instance)
8. [Phase 6 — Nextcloud: Register Context Chat Backend via AppAPI (Per Instance)](#8-phase-6--nextcloud-register-context-chat-backend-via-appapi-per-instance)
9. [Phase 7 — Nextcloud: Configure Background Job Workers (Per Instance)](#9-phase-7--nextcloud-configure-background-job-workers-per-instance)
10. [Phase 8 — TTS Considerations](#10-phase-8--tts-considerations)
11. [Phase 9 — GPU VRAM Optimization (Optional)](#11-phase-9--gpu-vram-optimization-optional)
12. [Phase 10 — Verification & Testing](#12-phase-10--verification--testing)
13. [Appendix A — Complete docker-compose.yml](#appendix-a--complete-docker-composeyml)
14. [Appendix B — Component Reference Table](#appendix-b--component-reference-table)
15. [Appendix C — Key Findings from Source Code Validation](#appendix-c--key-findings-from-source-code-validation)

---

## 1. Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                     GPU VM (Ubuntu + Docker + NVIDIA)                   │
│                                                                        │
│  ┌──────────────┐  ┌─────────────────────────────────────────────────┐ │
│  │   Ollama      │  │  Context Chat Backend ×4                       │ │
│  │  (shared LLM) │  │  (ghcr.io/nextcloud/context_chat_backend:5.3.0│ │
│  │  :11434       │  │                                                │ │
│  └──────────────┘  │  Each container runs internally:               │ │
│                     │  • main.py       (app, port 10034)             │ │
│  ┌──────────────┐  │  • main_em.py    (embedding server, :5000)     │ │
│  │  Whisper ASR  │  │  • PostgreSQL    (pgvector, internal)          │ │
│  │  (shared STT) │  │                                                │ │
│  │  :8300        │  │  Exposed as:                                   │ │
│  └──────────────┘  │  NC1→:10034 NC2→:10035 NC3→:10036 NC4→:10037  │ │
│                     └─────────────────────────────────────────────────┘ │
└──────────────┬──────────────┬──────────────┬──────────────┬────────────┘
               │              │              │              │
          ┌────┴───┐    ┌────┴───┐    ┌────┴───┐    ┌────┴───┐
          │ NC #1  │    │ NC #2  │    │ NC #3  │    │ NC #4  │
          │ (AIO)  │    │ (AIO)  │    │ (AIO)  │    │ (AIO)  │
          └────────┘    └────────┘    └────────┘    └────────┘

Data flow for Context Chat:
  NC → integration_openai → Ollama (:11434)     [LLM for Assistant]
  NC → CCB (:1003X) → nc_texttotext → NC → integration_openai → Ollama
       ↑                                        [LLM for Context Chat]
       └── internal pgvector DB + embedding server
```

### Key Design Decisions (Validated)

| Decision | Reason | Source |
|---|---|---|
| **CCB does NOT connect to Ollama directly** | It uses `nc_texttotext` LLM mode, which delegates to Nextcloud's Task Processing API | [`config.gpu.yaml` L45-46](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/config.gpu.yaml#L45-L46), [`models/loader.py` L11](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/context_chat_backend/models/loader.py#L11) |
| **Vector DB is pgvector (PostgreSQL)** | Only supported vector DB; embedded PostgreSQL runs inside each container | [`vectordb/loader.py` L8](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/context_chat_backend/vectordb/loader.py#L8) |
| **Each CCB runs its own embedding server** | `main_em.py` process via supervisord, using `multilingual-e5-large-instruct` model | [`supervisord.conf`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/supervisord.conf) |
| **One CCB container per NC instance** | Pgvector stores per-user document embeddings; sharing would mix tenants | [`vectordb/pgvector.py`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/context_chat_backend/vectordb/pgvector.py) |
| **Ollama is shared via `integration_openai`** | This app supports Ollama natively and provides Text2Text + STT providers | [`integration_openai` README](https://github.com/nextcloud/integration_openai/blob/661e4165330d51bcbaae91e658e8841814d0f880/README.md) |

---

## 2. Prerequisites

- [ ] GPU VM: Ubuntu with NVIDIA GPU passthrough working
- [ ] GPU VM: Docker + NVIDIA Container Toolkit installed
  ```bash
  # Verify GPU passthrough
  nvidia-smi
  # Verify Docker GPU access
  docker run --rm --gpus all nvidia/cuda:12.2.2-runtime-ubuntu22.04 nvidia-smi
  ```
- [ ] All 4 Nextcloud AIO instances running and accessible via HTTPS
- [ ] Network connectivity: NC VMs can reach GPU VM on ports 11434, 8300, 10034–10037
- [ ] **Nextcloud version ≥ 32** (required by CCB 5.3.0, see [`appinfo/info.xml` L32](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L32))

---

## 3. Phase 1 — GPU VM: Deploy Ollama (Shared LLM)

Ollama serves as the LLM backend. All 4 NC instances share it via `integration_openai`.

### Step 1.1: Create docker-compose for Ollama

```yaml
# file: /opt/ai-platform/docker-compose.ollama.yml
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  ollama_data:
```

### Step 1.2: Start and pull models

```bash
cd /opt/ai-platform
docker compose -f docker-compose.ollama.yml up -d

# Pull all models (P40 has 24 GB VRAM — Ollama loads/unloads dynamically)
docker exec ollama ollama pull llama3.1:8b          # Chat (~4.7 GB, ~6 GB VRAM)
docker exec ollama ollama pull mistral:7b            # Home Assistant agent (~4.1 GB, ~5 GB VRAM)
docker exec ollama ollama pull qwen2.5:14b           # Personal agent (~9 GB, ~11 GB VRAM)
docker exec ollama ollama pull qwen2.5-coder:14b     # Coding agent (~9 GB, ~11 GB VRAM)
```

#### Model Selection Rationale

| Use Case | Model | Size | VRAM | Why |
|---|---|---|---|---|
| **General chat** | `llama3.1:8b` | ~4.7 GB | ~6 GB | Fast, great all-rounder for Nextcloud Assistant |
| **Home Assistant agent** | `mistral:7b` | ~4.1 GB | ~5 GB | Excellent instruction-following, reliable structured/JSON output for HA service calls |
| **Personal agent** | `qwen2.5:14b` | ~9 GB | ~11 GB | Best reasoning at 14B, strong multilingual (German), good for planning/summarizing |
| **Coding agent** | `qwen2.5-coder:14b` | ~9 GB | ~11 GB | Purpose-built for code, outperforms CodeLlama and DeepSeek-Coder at this size |

#### VRAM Budget (NVIDIA Tesla P40 — 24 GB)

Ollama dynamically loads/unloads models. Configure via environment variables:

```yaml
environment:
  - OLLAMA_KEEP_ALIVE=5m           # unload idle models after 5 min
  - OLLAMA_NUM_PARALLEL=2           # max 2 concurrent requests per model
  - OLLAMA_MAX_LOADED_MODELS=2      # max 2 models in VRAM simultaneously
```

| Scenario | Models in VRAM | VRAM Used | Fits? |
|---|---|---|---|
| Chat + HA agent | llama3.1:8b + mistral:7b | ~11 GB | ✅ + embeddings |
| Personal agent solo | qwen2.5:14b | ~11 GB | ✅ + embeddings |
| Coding agent solo | qwen2.5-coder:14b | ~11 GB | ✅ + embeddings |
| Chat + Personal agent | llama3.1:8b + qwen2.5:14b | ~17 GB | ✅ tight |
| Two 14B models | qwen2.5:14b + qwen2.5-coder:14b | ~22 GB | ⚠️ leaves ~2 GB for embeddings |

> **Tip:** For a simpler setup, `qwen2.5:14b` alone can serve chat + personal + HA roles (3 roles, 1 model). Then only 2 models total are needed.

### Step 1.3: Verify

```bash
curl http://localhost:11434/api/tags
# Should list: llama3.1:8b, mistral:7b, qwen2.5:14b, qwen2.5-coder:14b

# Quick test with the chat model
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.1:8b","messages":[{"role":"user","content":"Hello"}]}'

# Quick test with the coding model
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder:14b","messages":[{"role":"user","content":"Write a Python hello world"}]}'
```

---

## 4. Phase 2 — GPU VM: Deploy Whisper STT (Shared)

> **Note:** `integration_openai` provides a SpeechToText provider that speaks the **OpenAI Whisper API format** (`/v1/audio/transcriptions`). The commonly used `onerahmet/openai-whisper-asr-webservice` exposes `/asr` instead. You need a service that is OpenAI-API compatible. Ollama does **not** provide STT. Options:
> - **Option A:** Use [LocalAI](https://localai.io) with Whisper model (exposes `/v1/audio/transcriptions`)
> - **Option B:** Use `onerahmet/openai-whisper-asr-webservice` if `integration_openai` can be configured for its endpoint
> - **Option C:** Use a dedicated Nextcloud STT ExApp like `stt_whisper2` from the External Apps page

### Step 2.1: Deploy Whisper (Option A — LocalAI recommended)

```yaml
# file: /opt/ai-platform/docker-compose.whisper.yml
services:
  localai-whisper:
    image: localai/localai:latest-gpu-nvidia-cuda-12
    container_name: localai-whisper
    restart: unless-stopped
    ports:
      - "8300:8080"
    environment:
      - MODELS_PATH=/models
      - THREADS=4
    volumes:
      - localai_models:/models
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  localai_models:
```

After starting, configure a Whisper model in LocalAI (it provides `/v1/audio/transcriptions`).

### Step 2.2: Verify

```bash
curl http://localhost:8300/models/apply -H "Content-Type: application/json" \
  -d '{"url": "github:go-skynet/model-gallery/whisper-base.yaml", "name": "whisper-1"}'
```

---

## 5. Phase 3 — GPU VM: Deploy Context Chat Backend ×4 (Per-Instance)

### Critical information from source code

Each CCB container internally runs (via [`supervisord.conf`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/supervisord.conf)):
1. **`main.py`** — FastAPI app on port 10034
2. **`main_em.py`** — Embedding server on internal port 5000
3. **PostgreSQL + pgvector** — Internal vector database

The **required environment variables** from [`example.env`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/example.env):

| Variable | Value | Required |
|---|---|---|
| `AA_VERSION` | `3.0.0` | Yes |
| `APP_ID` | `context_chat_backend` | Yes |
| `APP_DISPLAY_NAME` | `Context Chat Backend` | Yes |
| `APP_VERSION` | `5.3.0` | Yes |
| `APP_HOST` | `0.0.0.0` | Yes |
| `APP_PORT` | `10034` | Yes |
| `APP_SECRET` | unique per instance | Yes |
| `APP_PERSISTENT_STORAGE` | path inside container | Yes |
| `NEXTCLOUD_URL` | URL of target NC instance | Yes |
| `NVIDIA_VISIBLE_DEVICES` | `all` | Yes (GPU) |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute` | Yes (GPU) |
| `CUDA_VISIBLE_DEVICES` | `0` | Recommended |
| `EXTERNAL_DB` | PostgreSQL URI | Optional |
| `CC_EM_BASE_URL` | External embedding endpoint | Optional |

The **official Docker image** from [`appinfo/info.xml`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L35-L39):
```
ghcr.io/nextcloud/context_chat_backend:5.3.0
```

The **default LLM mode** from [`config.gpu.yaml` L45-46](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/config.gpu.yaml#L45-L46):
```yaml
llm:
  nc_texttotext:    # ← First entry = used. Delegates to Nextcloud's Task Processing
```

This means the CCB calls back to the Nextcloud instance's registered Text2Text provider (i.e., `integration_openai` → Ollama).

### Step 3.1: Create .env files for each instance

```bash
mkdir -p /opt/ai-platform/env
```

```dotenv
# file: /opt/ai-platform/env/nc1.env
AA_VERSION=3.0.0
APP_ID=context_chat_backend
APP_DISPLAY_NAME=Context Chat Backend
APP_VERSION=5.3.0
APP_HOST=0.0.0.0
APP_PORT=10034
APP_SECRET=CHANGE_ME_UNIQUE_SECRET_NC1
APP_PERSISTENT_STORAGE=/nc_app_context_chat_backend_data
NEXTCLOUD_URL=https://nc1.yourdomain.com
NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES=compute
CUDA_VISIBLE_DEVICES=0
CC_DOWNLOAD_MODELS_FROM_HF=true
```

Repeat for `nc2.env`, `nc3.env`, `nc4.env` — changing `APP_SECRET` and `NEXTCLOUD_URL` for each.

### Step 3.2: Create docker-compose for all 4 CCBs

```yaml
# file: /opt/ai-platform/docker-compose.ccb.yml
services:
  context-chat-nc1:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc1
    restart: unless-stopped
    ports:
      - "10034:10034"
    env_file: ./env/nc1.env
    volumes:
      - ccb_nc1_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  context-chat-nc2:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc2
    restart: unless-stopped
    ports:
      - "10035:10034"
    env_file: ./env/nc2.env
    volumes:
      - ccb_nc2_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  context-chat-nc3:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc3
    restart: unless-stopped
    ports:
      - "10036:10034"
    env_file: ./env/nc3.env
    volumes:
      - ccb_nc3_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  context-chat-nc4:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc4
    restart: unless-stopped
    ports:
      - "10037:10034"
    env_file: ./env/nc4.env
    volumes:
      - ccb_nc4_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  ccb_nc1_data:
  ccb_nc2_data:
  ccb_nc3_data:
  ccb_nc4_data:
```

### Step 3.3: Start CCBs

```bash
docker compose -f docker-compose.ccb.yml up -d
# First start will download embedding models from HuggingFace (~2-5 min)
# Monitor logs:
docker logs -f nc_app_context_chat_backend_nc1
```

### Step 3.4: Verify each CCB is running

```bash
# Each should return a response when the app is ready
curl http://localhost:10034/enabled
curl http://localhost:10035/enabled
curl http://localhost:10036/enabled
curl http://localhost:10037/enabled
```

---

## 6. Phase 4 — Nextcloud: Install Apps (Per Instance, In Order)

> **⚠️ Order matters!** From [`appinfo/info.xml`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L14-L19) and [README](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/README.md#L20-L25):
>
> *"Install the given apps for Context Chat to work as desired **in the given order**"*

On **each** of the 4 Nextcloud instances:

| Step | App | Install From | Notes |
|---|---|---|---|
| 1 | **AppAPI** | Apps page | Required for ExApp management |
| 2 | **Context Chat Backend** | External Apps page OR manual registration (Phase 6) | Install **before** the PHP app |
| 3 | **Context Chat** | Apps page | Same major.minor version as backend (5.3.x) |
| 4 | **Assistant** | Apps page | Universal AI frontend |
| 5 | **OpenAI/LocalAI Integration** (`integration_openai`) | Apps page | Provides Text2Text + STT providers via Ollama |

> **Note from the [README](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/README.md#L7-L12):**  
> *"Be mindful to install the backend before the Context Chat php app (Context Chat php app would send all the user-accessible files to the backend for indexing in the background.)"*

---

## 7. Phase 5 — Nextcloud: Configure integration_openai (Per Instance)

From the [`integration_openai` README](https://github.com/nextcloud/integration_openai/blob/661e4165330d51bcbaae91e658e8841814d0f880/README.md#L22-L25):

> *"Instead of connecting to the OpenAI API, you can also connect to a self-hosted Ollama instance"*

On **each** NC instance, go to **Admin Settings → Artificial Intelligence → OpenAI/LocalAI Integration**:

| Setting | Value |
|---|---|
| Service type | **Ollama** |
| Service URL | `http://<GPU_VM_IP>:11434` |
| Model for text generation | `llama3.1:8b` (general chat) or `qwen2.5:14b` (for richer reasoning) |
| Whisper STT endpoint | `http://<GPU_VM_IP>:8300` (if using LocalAI for STT) |

This provides:
- ✅ **Text generation** (Free prompt, Summarize, Headline, Chat) → used by Assistant
- ✅ **Text2Text Task Processing** → used by CCB's `nc_texttotext` LLM mode
- ✅ **SpeechToText** (if Whisper is configured)

---

## 8. Phase 6 — Nextcloud: Register Context Chat Backend via AppAPI (Per Instance)

From the [CCB README — Register as an Ex-App](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/README.md#L65-L78):

### Step 6.1: Create a manual deploy daemon (once per NC instance)

```bash
# On each NC instance (via occ command inside AIO container):
# <host> = GPU VM IP address
# <nextcloud_url> = this instance's URL
sudo -u www-data php occ app_api:daemon:register \
  --net host \
  manual_install "Manual Install" manual-install \
  http <GPU_VM_IP> https://ncX.yourdomain.com
```

> If Nextcloud is inside a Docker container (AIO), use `host.docker.internal` and add `--add-host=host.docker.internal:host-gateway` to the NC container. See [README](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/README.md#L68-L70).

### Step 6.2: Register the CCB (unique port per instance!)

```bash
# NC Instance 1 → port 10034
sudo -u www-data php occ app_api:app:register \
  context_chat_backend manual_install \
  --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"CHANGE_ME_UNIQUE_SECRET_NC1\",\"port\":10034,\"scopes\":[],\"system_app\":0}" \
  --force-scopes --wait-finish

# NC Instance 2 → port 10035
sudo -u www-data php occ app_api:app:register \
  context_chat_backend manual_install \
  --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"CHANGE_ME_UNIQUE_SECRET_NC2\",\"port\":10035,\"scopes\":[],\"system_app\":0}" \
  --force-scopes --wait-finish

# NC Instance 3 → port 10036
sudo -u www-data php occ app_api:app:register \
  context_chat_backend manual_install \
  --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"CHANGE_ME_UNIQUE_SECRET_NC3\",\"port\":10036,\"scopes\":[],\"system_app\":0}" \
  --force-scopes --wait-finish

# NC Instance 4 → port 10037
sudo -u www-data php occ app_api:app:register \
  context_chat_backend manual_install \
  --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"CHANGE_ME_UNIQUE_SECRET_NC4\",\"port\":10037,\"scopes\":[],\"system_app\":0}" \
  --force-scopes --wait-finish
```

> **⚠️ The `secret` must match the `APP_SECRET` in the corresponding `.env` file!**

### Step 6.3: Verify registration

```bash
sudo -u www-data php occ app_api:app:list
# Should show context_chat_backend as registered and enabled
```

To unregister if needed:
```bash
sudo -u www-data php occ app_api:app:unregister context_chat_backend --force
```

---

## 9. Phase 7 — Nextcloud: Configure Background Job Workers (Per Instance)

From the [CCB README](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/README.md#L30-L32) and [`appinfo/info.xml`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L21):

> *"To avoid task processing execution delay, setup at least 4 background job workers"*

On each NC instance, set up systemd-based cron workers:

```bash
# /etc/systemd/system/nextcloud-worker@.service
[Unit]
Description=Nextcloud background job worker %i
After=network.target

[Service]
User=www-data
ExecStart=/usr/bin/php -f /var/www/nextcloud/cron.php
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now nextcloud-worker@{1..4}
```

See full docs: https://docs.nextcloud.com/server/latest/admin_manual/ai/overview.html#improve-ai-task-pickup-speed

---

## 10. Phase 8 — TTS Considerations

**Current status:** There is no official Nextcloud ExApp that bridges Piper TTS to Nextcloud's `core:text2speech` Task Processing type (introduced in Nextcloud 32).

**Options:**

| Option | Approach | Pros | Cons |
|---|---|---|---|
| A | `integration_openai` + OpenAI-compatible TTS endpoint (e.g., LocalAI serving Piper) | Uses existing app | Requires LocalAI setup with Piper voice |
| B | Wait for an official Piper ExApp | Clean integration | Not yet available |
| C | Use `integration_openai` pointed at OpenAI's TTS API | Works immediately | Requires API key, not self-hosted |

**Recommended (Option A):** Add a Piper voice to the LocalAI instance from Phase 2 and configure `integration_openai` to use it for TTS.

---

## 11. Phase 9 — GPU VRAM Optimization (Optional)

Running 4 CCB instances each with their own embedding server is GPU-intensive. The embedding model (`multilingual-e5-large-instruct-q6_k.gguf`) uses ~2-3 GB VRAM per instance.

> **Note:** With the NVIDIA Tesla P40 (24 GiB VRAM) there is sufficient headroom to run all 4 embedding servers + Ollama without optimization. This phase is optional.

### Option: Shared External Embedding Server

From [`appinfo/info.xml`](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L59-L62):

> `CC_EM_BASE_URL` — *"Set this to an OpenAI-compatible endpoint. When set, the internal embedding server is not started."*

**Steps:**
1. Run one CCB instance normally (it starts its own embedding server on internal `:5000`)
2. For the other 3, set `CC_EM_BASE_URL` to point to a single shared OpenAI-compatible embedding endpoint
3. Or deploy a dedicated embedding server (e.g., via LocalAI or text-embeddings-inference)

Add to `.env` files for instances 2-4:
```dotenv
CC_EM_BASE_URL=http://<GPU_VM_IP>:5555/v1
# CC_EM_MODEL_NAME=multilingual-e5-large-instruct
```

This reduces GPU VRAM from ~12 GB (4× embedding) to ~3 GB (1× embedding).

---

## 12. Phase 10 — Verification & Testing

### Test Checklist

- [ ] **Ollama:** `curl http://<GPU_VM_IP>:11434/api/tags` returns models
- [ ] **Whisper:** `curl http://<GPU_VM_IP>:8300/v1/audio/transcriptions -F file=@test.wav` returns text
- [ ] **CCB:** `curl http://<GPU_VM_IP>:1003X/enabled` returns OK for each instance
- [ ] **NC Assistant:** Open Assistant in each NC, type a prompt → get LLM response
- [ ] **NC Context Chat:** Upload a document, wait for indexing, then ask a question about it
- [ ] **NC STT:** Use voice recording in Assistant → get transcription
- [ ] **Isolation:** Verify documents uploaded to NC1 are NOT searchable from NC2's Context Chat

### Monitoring

```bash
# GPU utilization
watch nvidia-smi

# CCB logs
docker logs -f nc_app_context_chat_backend_nc1

# CCB log files (inside container)
docker exec nc_app_context_chat_backend_nc1 ls /nc_app_context_chat_backend_data/logs/
```

---

## Appendix A — Complete docker-compose.yml

```yaml
# file: /opt/ai-platform/docker-compose.yml
# Complete combined compose file for the AI platform

services:
  # ═══ SHARED: Ollama LLM ═══
  # Models: llama3.1:8b (chat), mistral:7b (HA agent),
  #         qwen2.5:14b (personal agent), qwen2.5-coder:14b (coding agent)
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=5m
      - OLLAMA_NUM_PARALLEL=2
      - OLLAMA_MAX_LOADED_MODELS=2
    volumes:
      - ollama_data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  # ═══ SHARED: LocalAI (Whisper STT + optional Piper TTS) ═══
  localai:
    image: localai/localai:latest-gpu-nvidia-cuda-12
    container_name: localai
    restart: unless-stopped
    ports:
      - "8300:8080"
    volumes:
      - localai_models:/models
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  # ═══ PER-INSTANCE: Context Chat Backend ×4 ═══
  context-chat-nc1:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc1
    restart: unless-stopped
    ports:
      - "10034:10034"
    env_file: ./env/nc1.env
    volumes:
      - ccb_nc1_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  context-chat-nc2:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc2
    restart: unless-stopped
    ports:
      - "10035:10034"
    env_file: ./env/nc2.env
    volumes:
      - ccb_nc2_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  context-chat-nc3:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc3
    restart: unless-stopped
    ports:
      - "10036:10034"
    env_file: ./env/nc3.env
    volumes:
      - ccb_nc3_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  context-chat-nc4:
    image: ghcr.io/nextcloud/context_chat_backend:5.3.0
    container_name: nc_app_context_chat_backend_nc4
    restart: unless-stopped
    ports:
      - "10037:10034"
    env_file: ./env/nc4.env
    volumes:
      - ccb_nc4_data:/nc_app_context_chat_backend_data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  ollama_data:
  localai_models:
  ccb_nc1_data:
  ccb_nc2_data:
  ccb_nc3_data:
  ccb_nc4_data:
```

---

## Appendix B — Component Reference Table

| Component | Shared/Isolated | Image | Port | Source |
|---|---|---|---|---|
| Ollama | Shared ×1 | `ollama/ollama:latest` | 11434 | — |
| LocalAI (Whisper+TTS) | Shared ×1 | `localai/localai:latest-gpu-nvidia-cuda-12` | 8300 | — |
| CCB NC1 | Isolated | `ghcr.io/nextcloud/context_chat_backend:5.3.0` | 10034 | [info.xml](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L35-L39) |
| CCB NC2 | Isolated | same | 10035 | same |
| CCB NC3 | Isolated | same | 10036 | same |
| CCB NC4 | Isolated | same | 10037 | same |

---

## Appendix C — Key Findings from Source Code Validation

| # | Original Assumption | Actual (from source) | Impact |
|---|---|---|---|
| 1 | CCB connects to Ollama via `OLLAMA_URL` | CCB uses `nc_texttotext` which calls NC's Task Processing API. No `OLLAMA_URL` env var exists. | Must configure `integration_openai` on NC side instead |
| 2 | "Built-in vector DB" = embedded/simple | Vector DB is **PostgreSQL + pgvector**, running as a full process inside the container | Works as-is, but resource-heavy |
| 3 | Image is `appapi-dsp-http:latest` | Image is `ghcr.io/nextcloud/context_chat_backend:5.3.0` | Wrong image would fail |
| 4 | `NC_BASEURL`, `MODEL` env vars | Correct vars: `NEXTCLOUD_URL`, `APP_SECRET`, `APP_ID`, etc. | Registration would fail with wrong vars |
| 5 | CCB just needs port + volume | CCB runs 3 processes (app + embedding server + PostgreSQL) via supervisord | Much higher resource usage per container |
| 6 | Whisper via `onerahmet` image is OpenAI-compatible | That image uses `/asr` endpoint, not `/v1/audio/transcriptions` | Use LocalAI instead for `integration_openai` compatibility |
| 7 | LLM models: `nc_texttotext`, `llama`, `hugging_face`, `ctransformer` | Confirmed from [`models/loader.py` L11](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/context_chat_backend/models/loader.py#L11) | `nc_texttotext` is default and recommended for external LLM |
| 8 | Nextcloud version requirement | **Nextcloud ≥ 32** required ([`info.xml` L32](https://github.com/nextcloud/context_chat_backend/blob/2debcb2b410befa4cffe977ae47fbe7c545646b0/appinfo/info.xml#L32)) | Must verify NC version first |

---

## Appendix D — Ollama Model Strategy

### Loaded Models & Use-Case Mapping

| Model | Primary Use Case | Accessed Via | Notes |
|---|---|---|---|
| `llama3.1:8b` | Nextcloud Assistant chat, Context Chat LLM | `integration_openai` → Ollama | Default model for NC text generation |
| `mistral:7b` | Home Assistant conversation agent | HA Ollama integration → Ollama | Reliable JSON/structured output for service calls |
| `qwen2.5:14b` | Personal agent, planning, summarization | Open WebUI / API | Strong multilingual (German), best reasoning at 14B |
| `qwen2.5-coder:14b` | Code generation, debugging, review | Open WebUI / API | Purpose-built for code tasks |

### Home Assistant Integration

The Home Assistant VM (192.168.1.20) connects to Ollama on the GPU VM via the
[Ollama Conversation integration](https://www.home-assistant.io/integrations/ollama/).

**Configuration in Home Assistant:**

1. Go to **Settings → Devices & Services → Add Integration → Ollama**
2. Set the URL to `http://192.168.1.120:11434`
3. Select model: `mistral:7b`
4. Add a system prompt describing your smart home entities, e.g.:

```
You are a home automation assistant. You control a smart home via Home Assistant.
Available areas: Living Room, Kitchen, Bedroom, Office, Garden.
Available device types: lights, switches, climate, covers, media players.
When the user asks to control a device, respond with the appropriate service call.
Always confirm what action you took.
```

5. Go to **Settings → Voice assistants** and assign the Ollama agent as conversation agent

**Network requirement:** Home Assistant VM (192.168.1.20) must reach GPU VM (192.168.1.120:11434).

### Open WebUI Model Access

Open WebUI (http://192.168.1.120:3000) automatically discovers all Ollama models.
Users can select models from the dropdown:

- `llama3.1:8b` — quick chat
- `qwen2.5:14b` — deeper reasoning tasks
- `qwen2.5-coder:14b` — coding tasks
- `mistral:7b` — HA testing / structured output

### Consolidated (Minimal) Setup Alternative

If VRAM pressure is a concern or you prefer fewer models:

| Model | Roles | VRAM |
|---|---|---|
| `qwen2.5:14b` | Chat + Personal agent + HA agent | ~11 GB |
| `qwen2.5-coder:14b` | Coding agent | ~11 GB |