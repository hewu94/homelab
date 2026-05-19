# DPSG Cloud (NC1) — Setup Commands
# Run these in order. One step at a time.

# ═══════════════════════════════════════════════
# STEP 1: On GPU VM (ssh manager@192.168.1.120)
# ═══════════════════════════════════════════════
cd ~/ai-plattform
docker compose up -d context-chat-nc1
docker logs -f nc_app_context_chat_backend_nc1
# Wait for "Uvicorn running on http://localhost:5000" then Ctrl+C

# ═══════════════════════════════════════════════
# STEP 2: On NC1 VM (ssh dpsg@192.168.1.121)
# Install apps in this order:
# ═══════════════════════════════════════════════
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install app_api
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install integration_openai
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install context_chat
docker exec -u 33 nextcloud-aio-nextcloud php occ app:install assistant

# ═══════════════════════════════════════════════
# STEP 3: Configure integration_openai in Web UI
# ═══════════════════════════════════════════════
# Go to: https://dpsg-bruenninghausen.de
# Admin Settings -> AI -> OpenAI/LocalAI Integration
# Service URL: http://192.168.1.120:11434
# Enable: Ollama-specific features
# Model: llama3.1:8b

# ═══════════════════════════════════════════════
# STEP 4: Register manual deploy daemon
# (on NC1 VM)
# ═══════════════════════════════════════════════
docker exec -u 33 nextcloud-aio-nextcloud php occ app_api:daemon:register --net host manual_install "Manual Install" manual-install http 192.168.1.120 https://dpsg-bruenninghausen.de

# ═══════════════════════════════════════════════
# STEP 5: Register CCB (port 10034)
# Secret must match APP_SECRET in env/nc1.env
# (on NC1 VM)
# ═══════════════════════════════════════════════
docker exec -u 33 nextcloud-aio-nextcloud php occ app_api:app:register context_chat_backend manual_install --json-info "{\"appid\":\"context_chat_backend\",\"name\":\"Context Chat Backend\",\"daemon_config_name\":\"manual_install\",\"version\":\"5.3.0\",\"secret\":\"5ce6d094e49645aca81affdaf979ffd4030c53f6f70d453690e4d417cbaa3a8f\",\"port\":10034,\"scopes\":[],\"system_app\":0}" --force-scopes --wait-finish

# ═══════════════════════════════════════════════
# STEP 6: Scan files and run background worker
# (on NC1 VM)
# Repeat the scan command for each user on this instance
# ═══════════════════════════════════════════════
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan Admin
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Andre Schulze"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Bjoern Sprenger"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Corinna Wiemann"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Doris Gfeller"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Felix Frerich"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Admin Hermi"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Hermann Wuebbels"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Jennifer Martin"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Joel Trocha"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Johannes Rueters"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Jonas Pliska"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Jonas Wonneberg"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Julian Lider"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Laura Jungholt"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Laura Vogt"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Lea Lamberty"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Lena Jungholt"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Lena Middelhauve"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Patrick Brocksiepe"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Theresa List"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Timo Vogel"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Verena Bathe"
docker exec -u 33 nextcloud-aio-nextcloud php occ context_chat:scan "Vincent Dominik Vogt"
# Then run background worker for 10 minutes to process all files
docker exec -u 33 nextcloud-aio-nextcloud php occ background-job:worker -t 600

# ═══════════════════════════════════════════════
# STEP 7: Set up persistent cron
# (on NC1 VM)
# ═══════════════════════════════════════════════
# Run: crontab -e
# Add this line:
# */5 * * * * docker exec -u 33 nextcloud-aio-nextcloud php -f /var/www/html/cron.php
