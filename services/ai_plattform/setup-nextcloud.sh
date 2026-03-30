#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# setup-nextcloud.sh — Configure Nextcloud instances for AI Platform
# ═══════════════════════════════════════════════════════════════════
#
# This script runs the occ commands needed on each Nextcloud AIO instance
# to register the Context Chat Backend as an ExApp.
#
# Usage:
#   1. Update the variables below with your actual values
#   2. Copy this script to each NC AIO host (or run via SSH)
#   3. Run: sudo bash setup-nextcloud.sh <instance_number>
#      e.g.: sudo bash setup-nextcloud.sh 1
#
# Prerequisites:
#   - GPU VM docker-compose is up and CCBs are healthy
#   - AppAPI app is installed on the Nextcloud instance
#   - integration_openai app is installed and configured

set -euo pipefail

# ════════════════════════════════════════════════════════════════
# CONFIGURATION — UPDATE THESE VALUES BEFORE RUNNING
# ════════════════════════════════════════════════════════════════

GPU_VM_IP="CHANGE_ME"  # IP address of your GPU VM

# Nextcloud instance URLs (must match NEXTCLOUD_URL in env files)
NC_URLS=(
  ""  # placeholder for index 0
  "https://nc1.yourdomain.com"
  "https://nc2.yourdomain.com"
  "https://nc3.yourdomain.com"
  "https://nc4.yourdomain.com"
)

# APP_SECRET values — MUST match those in env/nc{1..4}.env
NC_SECRETS=(
  ""  # placeholder for index 0
  "5ce6d094e49645aca81affdaf979ffd4030c53f6f70d453690e4d417cbaa3a8f"
  "62cbd88ed7644cbdb8822bfa58aca4c2654714be6da647e5ab8a5a7f1c38506d"
  "9d937bc18eeb4ec4b54ff58b47cfb43cc1115697bfce48958af464950dfe4a66"
  "79a57e579ded47ed8532a3d0410d9e37599eed3bed5e42b8a97da2154e87f239"
)

# CCB port mapping: NC1→10034, NC2→10035, NC3→10036, NC4→10037
NC_PORTS=(0 10034 10035 10036 10037)

# Path to occ inside AIO — adjust if your setup differs
# For AIO: docker exec --user www-data -it nextcloud-aio-nextcloud php occ
OCC_CMD="docker exec --user www-data nextcloud-aio-nextcloud php occ"

# ════════════════════════════════════════════════════════════════
# SCRIPT
# ════════════════════════════════════════════════════════════════

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[1-4]$ ]]; then
  echo "Usage: sudo bash setup-nextcloud.sh <instance_number>"
  echo "  instance_number: 1, 2, 3, or 4"
  exit 1
fi

INSTANCE=$1
NC_URL="${NC_URLS[$INSTANCE]}"
SECRET="${NC_SECRETS[$INSTANCE]}"
PORT="${NC_PORTS[$INSTANCE]}"

if [[ "$GPU_VM_IP" == "CHANGE_ME" ]]; then
  echo "ERROR: Update GPU_VM_IP in this script before running."
  exit 1
fi

if [[ "$NC_URL" == *"yourdomain.com"* ]]; then
  echo "WARNING: NC_URL still contains 'yourdomain.com'. Are you sure? (Ctrl-C to cancel, Enter to continue)"
  read -r
fi

echo "═══════════════════════════════════════════════════════"
echo " Setting up NC Instance $INSTANCE"
echo " URL:    $NC_URL"
echo " CCB:    http://$GPU_VM_IP:$PORT"
echo "═══════════════════════════════════════════════════════"

# ── Step 1: Install required apps (skip if already installed) ──
echo ""
echo "Step 1: Checking/installing required Nextcloud apps..."
echo "  (Install order: AppAPI → Context Chat Backend → Context Chat → Assistant → OpenAI Integration)"
echo ""

for APP in app_api context_chat assistant integration_openai; do
  if $OCC_CMD app:list | grep -q "  - $APP:"; then
    echo "  ✓ $APP already installed"
  else
    echo "  → Installing $APP..."
    $OCC_CMD app:install "$APP" || echo "  ⚠ Could not install $APP — install manually from Apps page"
  fi
done

# ── Step 2: Register the manual deploy daemon ──
echo ""
echo "Step 2: Registering AppAPI manual deploy daemon..."

# Unregister first if it exists (idempotent)
$OCC_CMD app_api:daemon:unregister manual_install 2>/dev/null || true

$OCC_CMD app_api:daemon:register \
  --net host \
  manual_install "Manual Install" manual-install \
  http "$GPU_VM_IP" "$NC_URL"

echo "  ✓ Daemon registered"

# ── Step 3: Register Context Chat Backend ExApp ──
echo ""
echo "Step 3: Registering Context Chat Backend ExApp on port $PORT..."

# Unregister first if it exists (idempotent)
$OCC_CMD app_api:app:unregister context_chat_backend --force 2>/dev/null || true

$OCC_CMD app_api:app:register \
  context_chat_backend manual_install \
  --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"$SECRET\",\"port\":$PORT,\"scopes\":[],\"system_app\":0}" \
  --force-scopes --wait-finish

echo "  ✓ Context Chat Backend registered"

# ── Step 4: Verify registration ──
echo ""
echo "Step 4: Verifying..."
$OCC_CMD app_api:app:list

# ── Step 5: Reminder for integration_openai configuration ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo " MANUAL STEPS REMAINING (do in NC Admin Settings):"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " 1. Go to Admin Settings → Artificial Intelligence → OpenAI/LocalAI Integration"
echo "    • Service type:           Ollama"
echo "    • Service URL:            http://$GPU_VM_IP:11434"
echo "    • Text generation model:  llama3.1:8b (or your chosen model)"
echo "    • Whisper STT endpoint:   http://$GPU_VM_IP:8300"
echo ""
echo " 2. Install 'Context Chat' app from Apps page (if not done)"
echo "    • Must be same major.minor version as backend (5.3.x)"
echo ""
echo " 3. Test: Open Assistant → type a prompt → verify LLM response"
echo ""
echo " Done! Instance $INSTANCE is configured."
