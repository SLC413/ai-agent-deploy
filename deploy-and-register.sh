#!/usr/bin/env bash
set -euo pipefail
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { log "FATAL: $*"; exit 1; }

DS="${DEPLOY_SERVER:-http://43.160.245.20:9900}"
API="${ADMIN_API:-https://ai.nika8.com/api}"
: "${DEEPSEEK_API_KEY:?need DEEPSEEK_API_KEY}"
: "${ADMIN_PASSWORD:?need ADMIN_PASSWORD}"
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
git init 2>/dev/null && git remote add origin https://github.com/openclaw/openclaw.git 2>/dev/null || true
git config --global --add safe.directory /home/ubuntu/openclaw 2>/dev/null || true

# 6. Onboarding
log "Onboarding (takes several minutes)..."
curl -sL "${DS}/setup-openclaw-ubuntu.sh" -o /tmp/setup.sh 2>/dev/null || true
if [ -f /tmp/setup.sh ] && [ -s /tmp/setup.sh ]; then
  DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY}" bash /tmp/setup.sh > /tmp/onboard.log 2>&1 &
else
  curl -sL https://raw.githubusercontent.com/BIDXOM/setup-openclaw-ubuntu/refs/heads/main/setup-openclaw-ubuntu.sh | DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY}" bash > /tmp/onboard.log 2>&1 &
fi
OPID=$!
while kill -0 $OPID 2>/dev/null; do sleep 15; done
wait $OPID || true
pkill -f "openclaw onboard" 2>/dev/null || true
sleep 3
tail -10 /tmp/onboard.log
log "Onboarding done"

# 7. Dist rebuild
log "Rebuilding dist..."
cd /home/ubuntu/openclaw && rm -rf dist
CI=true node scripts/run-node.mjs --version 2>&1 | tail -3
ls dist/index.js || die "dist build failed"
log "Dist OK"

# 8. Config
log "Config..."
mkdir -p ~/.local/bin ~/.local/share/pnpm/bin ~/.config/systemd/user
cat > ~/.local/bin/openclaw << 'W'
#!/usr/bin/env bash
cd "$HOME/openclaw" || exit 1
exec "$HOME/.npm-global/bin/pnpm" openclaw "$@"
W
chmod +x ~/.local/bin/openclaw
ln -sf ~/.npm-global/bin/pnpm ~/.local/share/pnpm/bin/pnpm 2>/dev/null || true
cd ~/openclaw && CI=true ~/.npm-global/bin/pnpm approve-builds node-pty 2>/dev/null || true
grep -q npm-global ~/.bashrc 2>/dev/null || echo "export PATH=\"\$HOME/.local/bin:\$HOME/.npm-global/bin:\$HOME/.local/share/pnpm/bin:\$PATH\"" >> ~/.bashrc
S=~/.config/systemd/user/openclaw-gateway.service
if [ -f "$S" ] && ! grep -q npm-global "$S" 2>/dev/null; then
  sed -i "s|Environment=PATH=.*|Environment=PATH=/usr/bin:/usr/local/bin:/bin:/home/ubuntu/.npm-global/bin:/home/ubuntu/.local/share/pnpm/bin:/home/ubuntu/.local/bin:/home/ubuntu/bin|" "$S"
fi
log "Config OK"

# 9. Register
log "Registering to hot pool..."
python3 /tmp/register-agent.py 2>&1 && log "Register OK" || log "Register had issues (non-fatal)"

# 10. Gateway
log "Starting Gateway..."
rm -f ~/.openclaw/state/openclaw.sqlite* 2>/dev/null
sudo loginctl enable-linger ubuntu 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user start openclaw-gateway 2>/dev/null || true
sleep 20
HEALTH=$(curl -s -m 5 http://127.0.0.1:18789/health 2>/dev/null || echo "FAIL")
echo "$HEALTH" | grep -q "ok.*true" && log "Gateway LIVE" || log "Gateway: ${HEALTH}"

log "=== DEPLOY COMPLETE ==="
