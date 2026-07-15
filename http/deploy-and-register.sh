#!/usr/bin/env bash
set -euo pipefail
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { log "FATAL: $*"; exit 1; }

DS="${DEPLOY_SERVER:-http://43.160.245.20:9900}"
export ADMIN_API="${ADMIN_API:-https://www.nika8.com/api}"
: "${DEEPSEEK_API_KEY:?need DEEPSEEK_API_KEY}"
: "${ADMIN_API_KEY:?need ADMIN_API_KEY}"
export AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"
export CI=true

IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ip.sb 2>/dev/null || echo unknown)
log "Start deploy - IP: ${IP}"

# 1. Baseline
log "Downloading baseline..."
sudo rm -rf /home/ubuntu/openclaw /home/ubuntu/.openclaw 2>/dev/null
sudo mkdir -p /home/ubuntu/openclaw
curl -sL "${DS}/openclaw-baseline.tar.gz" | sudo tar xzf - -C /home/ubuntu/openclaw
sudo chown -R ubuntu:ubuntu /home/ubuntu/openclaw
ls /home/ubuntu/openclaw/package.json || die "baseline failed"

# 2. System deps
log "System deps..."
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq curl git ca-certificates gnupg unzip python3 jq build-essential >/dev/null 2>&1
log "Deps OK"

# 3. Swap
if [ ! -f /swapfile ]; then sudo fallocate -l 12G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile; fi

# 4. Node
log "Node..." 
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs >/dev/null 2>&1
fi
npm install -g pnpm@latest >/dev/null 2>&1 || sudo npm install -g pnpm@latest >/dev/null 2>&1
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"
log "Node $(node --version)"

# 5. China check
LATENCY=$(curl -s -o /dev/null -w "%{time_total}" --connect-timeout 5 https://registry.npmjs.org 2>/dev/null || echo 99)
if [ "${LATENCY%%.*}" -ge 2 ]; then
  log "China network - using mirror"
  echo "registry=https://registry.npmmirror.com" > /home/ubuntu/openclaw/.npmrc
  mkdir -p /home/ubuntu/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs
  curl -sL "${DS}/matrix-sdk-crypto.linux-x64-gnu.node" -o /home/ubuntu/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/matrix-sdk-crypto.linux-x64-gnu.node 2>/dev/null || true
fi

cd /home/ubuntu/openclaw
echo "pnpm.allowUnusedPatches=true" >> .npmrc
git init 2>/dev/null || true && git remote add origin 2>/dev/null || true https://github.com/openclaw/openclaw.git 2>/dev/null || true
git config --global --add safe.directory /home/ubuntu/openclaw 2>/dev/null || true

# Install dependencies (package.json already patched for pnpm v11)

# baseline 常带过期 patchedDependencies → ERR_PNPM_UNUSED_PATCH
python3 << 'PY'
import json
from pathlib import Path
p = Path("/home/ubuntu/openclaw/package.json")
cfg = json.loads(p.read_text())
pnpm_cfg = cfg.setdefault("pnpm", {})
pnpm_cfg["allowUnusedPatches"] = True
pnpm_cfg["allowNonAppliedPatches"] = True
# 直接清空 patchedDependencies，避免版本漂移再踩 ERR_PNPM_UNUSED_PATCH
patched = pnpm_cfg.get("patchedDependencies") or {}
if patched:
    print(f"cleared {len(patched)} patchedDependencies entries")
    pnpm_cfg["patchedDependencies"] = {}
p.write_text(json.dumps(cfg, indent=2) + "\n")
print("pnpm.allowUnusedPatches=true")
PY

# 6. Setup (baseline pre-built, skip pnpm onboarding)
log "Setup (baseline v2026.6.11 pre-built, includes pnpm install)..."
cd /home/ubuntu/openclaw
git init 2>/dev/null || true
git remote add origin 2>/dev/null || true https://github.com/openclaw/openclaw.git 2>/dev/null
git config --global --add safe.directory /home/ubuntu/openclaw 2>/dev/null

# Install dependencies (package.json already patched for pnpm v11)
log "  pnpm install (may take 1-2 minutes)..."
pnpm install 2>&1 | tail -5
[ -d node_modules ] || die "pnpm install failed"
log "  pnpm install OK"

# Generate gateway config
mkdir -p /home/ubuntu/.openclaw
TOKEN=$(python3 -c "import secrets;print(secrets.token_hex(32))")
cat > /home/ubuntu/.openclaw/openclaw.json << JSONEOF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "auth": { "token": "$TOKEN" },
    "http": { "endpoints": { "chatCompletions": { "enabled": true } } }
  },
  "plugins": { "entries": { "admin-http-rpc": { "enabled": true } } },
  "agents": { "defaults": { "reasoningDefault": "off", "thinkingDefault": "off" } },
  "meta": { "lastTouchedVersion": "2026.6.11" },
  "wizard": { "lastRunVersion": "2026.6.11" }
}
JSONEOF

# Create systemd service
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/openclaw-gateway.service << UNITEOF
[Unit]
Description=OpenClaw Gateway (v2026.6.11)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/node /home/ubuntu/openclaw/dist/index.js gateway --port 18789
Restart=always
RestartSec=5
RestartPreventExitStatus=78
Environment=HOME=/home/ubuntu
Environment=TMPDIR=/tmp
Environment=PATH=/usr/bin:/usr/local/bin:/bin:/home/ubuntu/.npm-global/bin:/home/ubuntu/.local/share/pnpm/bin:/home/ubuntu/.local/bin
Environment=OPENCLAW_GATEWAY_PORT=18789
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
[Install]
WantedBy=default.target
UNITEOF

[ -f /home/ubuntu/.openclaw/openclaw.json ] || die "Failed to create openclaw.json"
log "Setup done"

# user systemd needs these when launched from a system unit
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# Gateway already configured in JSON

# Config (minimal)
log "Config..."
grep -q npm-global ~/.bashrc 2>/dev/null || echo "export PATH=\"\$HOME/.local/bin:\$HOME/.npm-global/bin:\$PATH\"" >> ~/.bashrc
log "Config OK"

# 9. Gateway（先启动，再注册）
log "Starting Gateway..."
# 确保 DEEPSEEK key 写入 user systemd 服务（避免 sed 分隔符冲突，用 |）
S=~/.config/systemd/user/openclaw-gateway.service
if [ -f "$S" ] && ! grep -q '^Environment=DEEPSEEK_API_KEY=' "$S" 2>/dev/null; then
  # append 文本不受 sed 分隔符影响；key 含换行会坏，DeepSeek key 通常无此问题
  sed -i "/^\[Service\]/a Environment=DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}" "$S"
  sed -i "/^\[Service\]/a Environment=OPENAI_API_KEY=${DEEPSEEK_API_KEY}" "$S"
  sed -i "/^\[Service\]/a Environment=OPENAI_BASE_URL=https://api.deepseek.com" "$S"
fi
rm -f ~/.openclaw/state/openclaw.sqlite* 2>/dev/null
sudo loginctl enable-linger ubuntu 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed openclaw-gateway 2>/dev/null || true
systemctl --user start openclaw-gateway 2>/dev/null || true
sleep 20
HEALTH=$(curl -s -m 5 http://127.0.0.1:18789/health 2>/dev/null || echo "FAIL")
echo "$HEALTH" | grep -q "ok.*true" && log "Gateway LIVE" || log "Gateway: ${HEALTH}"

# 10. Register
log "Registering to hot pool..."
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ip.sb 2>/dev/null || echo "${IP}")
python3 /tmp/register-agent.py "$ADMIN_API_KEY" "$PUBLIC_IP" "$AGENT_PROVIDER" 2>&1 \
  && log "Register OK" || log "Register had issues (non-fatal)"

log "=== DEPLOY COMPLETE ==="
