#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# verify.sh — Health check for the Nextcloud AI Platform (GPU VM)
# ═══════════════════════════════════════════════════════════════════
#
# Run on the GPU VM after docker-compose up to verify all services.
# Usage: bash verify.sh [GPU_VM_IP]
#   GPU_VM_IP defaults to localhost

set -uo pipefail

HOST="${1:-localhost}"
PASS=0
FAIL=0
WARN=0

check() {
  local name="$1"
  local url="$2"
  local expect="${3:-200}"

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null) || code="000"

  if [[ "$code" == "$expect" ]]; then
    echo "  ✓ $name — HTTP $code"
    ((PASS++))
  else
    echo "  ✗ $name — HTTP $code (expected $expect)"
    ((FAIL++))
  fi
}

echo "═══════════════════════════════════════════════════════"
echo " Nextcloud AI Platform — Health Check"
echo " Target: $HOST"
echo "═══════════════════════════════════════════════════════"

# ── Docker containers ──
echo ""
echo "1. Docker Containers"
echo "─────────────────────"

EXPECTED_CONTAINERS=("ollama" "localai" "open-webui" "nc_app_context_chat_backend_nc1" "nc_app_context_chat_backend_nc2" "nc_app_context_chat_backend_nc3" "nc_app_context_chat_backend_nc4")

for c in "${EXPECTED_CONTAINERS[@]}"; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null) || STATUS="not found"
  if [[ "$STATUS" == "running" ]]; then
    echo "  ✓ $c — running"
    ((PASS++))
  else
    echo "  ✗ $c — $STATUS"
    ((FAIL++))
  fi
done

# ── Ollama ──
echo ""
echo "2. Ollama LLM"
echo "─────────────────────"
check "Ollama API" "http://$HOST:11434/api/tags"

MODEL_COUNT=$(curl -s "http://$HOST:11434/api/tags" 2>/dev/null | grep -c '"name"' || echo 0)
EXPECTED_MODELS=("llama3.1:8b" "mistral" "qwen2.5:14b" "qwen2.5-coder")
if [[ "$MODEL_COUNT" -ge ${#EXPECTED_MODELS[@]} ]]; then
  echo "  ✓ Models loaded: $MODEL_COUNT"
  curl -s "http://$HOST:11434/api/tags" 2>/dev/null | grep '"name"' | sed 's/.*"name":"\([^"]*\)".*/    → \1/'
elif [[ "$MODEL_COUNT" -gt 0 ]]; then
  echo "  ⚠ Only $MODEL_COUNT model(s) found (expected ${#EXPECTED_MODELS[@]})"
  curl -s "http://$HOST:11434/api/tags" 2>/dev/null | grep '"name"' | sed 's/.*"name":"\([^"]*\)".*/    → \1/'
  echo "  Missing models? Run:"
  echo "    docker exec ollama ollama pull llama3.1:8b"
  echo "    docker exec ollama ollama pull mistral:7b"
  echo "    docker exec ollama ollama pull qwen2.5:14b"
  echo "    docker exec ollama ollama pull qwen2.5-coder:14b"
  ((WARN++))
else
  echo "  ⚠ No models pulled yet! Run:"
  echo "    docker exec ollama ollama pull llama3.1:8b"
  echo "    docker exec ollama ollama pull mistral:7b"
  echo "    docker exec ollama ollama pull qwen2.5:14b"
  echo "    docker exec ollama ollama pull qwen2.5-coder:14b"
  ((WARN++))
fi

# ── LocalAI / Whisper ──
echo ""
echo "3. LocalAI (Whisper STT)"
echo "─────────────────────"
check "LocalAI API" "http://$HOST:8300/v1/models"

# ── Context Chat Backends ──
echo ""
echo "4. Context Chat Backends"
echo "─────────────────────"

for i in 1 2 3 4; do
  PORT=$((10033 + i))
  check "CCB NC$i (:$PORT)" "http://$HOST:$PORT/enabled"
done

# ── GPU ──
echo ""
echo "5. GPU Status"
echo "─────────────────────"
if command -v nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  GPU_MEM=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)
  echo "  ✓ GPU: $GPU_NAME"
  echo "    VRAM: $GPU_MEM"
  ((PASS++))
else
  echo "  ⚠ nvidia-smi not found (run this on the GPU VM)"
  ((WARN++))
fi

# ── Network ports ──
echo ""
echo "6. Port Accessibility (from GPU VM)"
echo "─────────────────────"

for PORT in 11434 3000 8300 10034 10035 10036 10037; do
  if ss -tln 2>/dev/null | grep -q ":$PORT " || netstat -tln 2>/dev/null | grep -q ":$PORT "; then
    echo "  ✓ Port $PORT — listening"
    ((PASS++))
  else
    echo "  ✗ Port $PORT — not listening"
    ((FAIL++))
  fi
done

# ── Summary ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "═══════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo " Next steps for failures:"
  echo "   • Check logs: docker logs <container_name>"
  echo "   • Verify GPU: docker run --rm --gpus all nvidia/cuda:12.2.2-runtime-ubuntu22.04 nvidia-smi"
  echo "   • CCB first start takes 2-5 min to download embedding models"
  exit 1
fi

if [[ $WARN -gt 0 ]]; then
  echo ""
  echo " Warnings present — check items marked with ⚠"
fi

exit 0
