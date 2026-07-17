#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  {
  log "FATAL: $*"
  if [ -f /tmp/deploy-step.log ]; then
    log "--- last deploy-step.log (tail 80) ---"
    tail -80 /tmp/deploy-step.log || true
  fi
  exit 1
}
step() { log "======== $* ========"; }

DS="${DEPLOY_SERVER:-http://43.160.245.20:9900}"
export ADMIN_API="${ADMIN_API:-https://www.nika8.com/api}"
: "${DEEPSEEK_API_KEY:?need DEEPSEEK_API_KEY}"
: "${ADMIN_API_KEY:?need ADMIN_API_KEY}"
export AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"
export CI=true

IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null \
  || curl -s --connect-timeout 5 ip.sb 2>/dev/null \
  || echo unknown)
step "START deploy"
log "Public IP: ${IP}"
log "DEPLOY_SERVER: ${DS}"
log "ADMIN_API: ${ADMIN_API}"
log "AGENT_PROVIDER: ${AGENT_PROVIDER}"
log "DEEPSEEK_API_KEY set: $([ -n "${DEEPSEEK_API_KEY}" ] && echo yes || echo no) (len=${#DEEPSEEK_API_KEY})"
log "ADMIN_API_KEY set: $([ -n "${ADMIN_API_KEY}" ] && echo yes || echo no) (len=${#ADMIN_API_KEY})"

# 1. Baseline
step "1/10 Download baseline"
sudo rm -rf /home/ubuntu/openclaw /home/ubuntu/.openclaw 2>/dev/null || true
sudo mkdir -p /home/ubuntu/openclaw
log "curl ${DS}/openclaw-baseline.tar.gz ..."
if ! curl -fL --connect-timeout 30 --max-time 600 "${DS}/openclaw-baseline.tar.gz" \
  | sudo tar xzf - -C /home/ubuntu/openclaw; then
  die "baseline download/extract failed from ${DS}/openclaw-baseline.tar.gz"
fi
sudo chown -R ubuntu:ubuntu /home/ubuntu/openclaw
[ -f /home/ubuntu/openclaw/package.json ] || die "baseline missing package.json"
log "baseline OK: $(du -sh /home/ubuntu/openclaw | awk '{print $1}')"
log "dist present: $([ -f /home/ubuntu/openclaw/dist/index.js ] && echo yes || echo NO)"
python3 -c "import json; print('package.json name/version:', json.load(open('/home/ubuntu/openclaw/package.json')).get('name'), json.load(open('/home/ubuntu/openclaw/package.json')).get('version'))" 2>/dev/null || true

# 2. System deps
step "2/10 System deps"
sudo apt-get update -qq 2>/dev/null || log "WARN: apt-get update failed (continuing)"
sudo apt-get install -y -qq curl git ca-certificates gnupg unzip python3 jq build-essential \
  >/tmp/deploy-step.log 2>&1 || die "apt-get install failed"
log "Deps OK"

# 3. Swap
step "3/10 Swap"
if [ -f /swapfile ] || swapon --show 2>/dev/null | grep -q /swapfile; then
  log "swap already present"
  free -h | head -2 || true
else
  log "creating 12G swapfile..."
  sudo fallocate -l 12G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  log "swap enabled"
  free -h | head -2 || true
fi

# 4. Node + pnpm
step "4/10 Node + pnpm"
if ! command -v node >/dev/null 2>&1; then
  log "installing Node 24..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/tmp/deploy-step.log 2>&1 \
    || die "nodesource setup failed"
  sudo apt-get install -y -qq nodejs >/tmp/deploy-step.log 2>&1 || die "nodejs install failed"
fi
log "Node $(node --version) npm $(npm --version)"

# 用户态 pnpm，避免全局权限问题
mkdir -p "$HOME/.npm-global" "$HOME/.local/bin" "$HOME/.local/share/pnpm/bin"
npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"
if ! command -v pnpm >/dev/null 2>&1; then
  log "installing pnpm..."
  npm install -g pnpm@latest >/tmp/deploy-step.log 2>&1 \
    || sudo npm install -g pnpm@latest >/tmp/deploy-step.log 2>&1 \
    || die "pnpm install failed"
fi
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"
log "pnpm $(pnpm --version 2>/dev/null || echo MISSING)"
command -v pnpm >/dev/null 2>&1 || die "pnpm not on PATH after install"

# 5. China mirror
step "5/10 Network / mirror"
LATENCY=$(curl -s -o /dev/null -w "%{time_total}" --connect-timeout 5 https://registry.npmjs.org 2>/dev/null || echo 99)
log "npmjs latency: ${LATENCY}s"
cd /home/ubuntu/openclaw
if [ "${LATENCY%%.*}" -ge 2 ] 2>/dev/null; then
  log "China network - enabling npmmirror"
  echo "registry=https://registry.npmmirror.com" > /home/ubuntu/openclaw/.npmrc
  mkdir -p /home/ubuntu/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs
  if curl -fL --connect-timeout 20 --max-time 120 \
    "${DS}/matrix-sdk-crypto.linux-x64-gnu.node" \
    -o /home/ubuntu/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/matrix-sdk-crypto.linux-x64-gnu.node \
    >/tmp/deploy-step.log 2>&1; then
    log "matrix-sdk binary preloaded"
  else
    log "WARN: matrix-sdk binary download failed (non-fatal)"
  fi
else
  log "npmjs OK, no mirror"
  : > /home/ubuntu/openclaw/.npmrc
fi

# 6. Git + patch package.json
step "6/10 Prepare package.json / git"
git init >/dev/null 2>&1 || true
git remote remove origin >/dev/null 2>&1 || true
git remote add origin https://github.com/openclaw/openclaw.git >/dev/null 2>&1 || true
git config --global --add safe.directory /home/ubuntu/openclaw >/dev/null 2>&1 || true
log "git remotes: $(git remote -v 2>/dev/null | tr '\n' ' ' || echo none)"

python3 << 'PY'
import json
from pathlib import Path
p = Path("/home/ubuntu/openclaw/package.json")
cfg = json.loads(p.read_text())
pnpm_cfg = cfg.setdefault("pnpm", {})
pnpm_cfg["allowUnusedPatches"] = True
pnpm_cfg["allowNonAppliedPatches"] = True

# matrix-sdk-crypto-nodejs 0.6.1+ 支持 MATRIX_SDK_CRYPTO_DOWNLOADS_BASE_URL 环境变量
# baseline 锁了 0.6.0，直接升级 extensions/matrix/package.json 中的精确版本
matrix_pkg = Path("/home/ubuntu/openclaw/extensions/matrix/package.json")
if matrix_pkg.exists():
    mcfg = json.loads(matrix_pkg.read_text())
    mcfg["dependencies"]["@matrix-org/matrix-sdk-crypto-nodejs"] = "0.6.1"
    mcfg["dependencies"]["@matrix-org/matrix-sdk-crypto-wasm"] = "18.3.1"
    matrix_pkg.write_text(json.dumps(mcfg, indent=2) + "\n")
    print("[patch] @matrix-org/matrix-sdk-crypto-nodejs -> 0.6.1")

patched = pnpm_cfg.get("patchedDependencies") or {}
if patched:
    print(f"[patch] cleared {len(patched)} patchedDependencies entries")
    pnpm_cfg["patchedDependencies"] = {}
else:
    print("[patch] no patchedDependencies to clear")
p.write_text(json.dumps(cfg, indent=2) + "\n")
print("[patch] allowUnusedPatches=true written")
PY

# 7. pnpm install
step "7/10 pnpm install"

# matrix-sdk-crypto-nodejs v0.6.1+ 支持此环境变量，
# 设置后 postinstall 从内网镜像下载二进制，不再走 GitHub Releases
# 覆盖 MATRIX_SDK_CRYPTO_BASE_URL 可切换镜像源
export MATRIX_SDK_CRYPTO_DOWNLOADS_BASE_URL="${MATRIX_SDK_CRYPTO_BASE_URL:-https://training.xhl413.com/binaries}"

cd /home/ubuntu/openclaw
rm -f npm-shrinkwrap.json
# 保留 pnpm-lock.yaml 若存在，仅在 install 失败时再删重试
log "running: pnpm install (full log -> /tmp/pnpm-install.log)"
set +e
pnpm install > /tmp/pnpm-install.log 2>&1
PNPM_RC=$?
set -e
tail -30 /tmp/pnpm-install.log || true
if [ "$PNPM_RC" -ne 0 ] || [ ! -d node_modules ]; then
  log "WARN: pnpm install failed (rc=${PNPM_RC}), retry without lockfile..."
  rm -f pnpm-lock.yaml npm-shrinkwrap.json
  set +e
  pnpm install > /tmp/pnpm-install.log 2>&1
  PNPM_RC=$?
  set -e
  tail -30 /tmp/pnpm-install.log || true
fi
[ "$PNPM_RC" -eq 0 ] || die "pnpm install failed rc=${PNPM_RC}, see /tmp/pnpm-install.log"
[ -d node_modules ] || die "node_modules missing after pnpm install"
[ -f dist/index.js ] || die "dist/index.js missing — baseline 不完整，无法启动 gateway"
log "pnpm install OK; node_modules=$(du -sh node_modules 2>/dev/null | awk '{print $1}')"

# 安装微信插件（渠道配置留给岗前培训）
npm install @tencent-weixin/openclaw-weixin@latest --no-save --legacy-peer-deps 2>/dev/null || \
  log "WARN: weixin plugin npm install failed (non-fatal)"
export PATH="$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"
~/.npm-global/bin/pnpm openclaw plugins install @tencent-weixin/openclaw-weixin 2>/dev/null || \
  log "WARN: weixin plugin openclaw install failed (non-fatal)"

# 8. Write openclaw.json + systemd unit
step "8/10 Write config + systemd unit"
mkdir -p /home/ubuntu/.openclaw ~/.config/systemd/user ~/.local/bin
TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
cat > /home/ubuntu/.openclaw/openclaw.json << JSONEOF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "auth": { "mode": "token", "token": "${TOKEN}" },
    "http": { "endpoints": { "chatCompletions": { "enabled": true } } }
  },
  "plugins": { "entries": { "admin-http-rpc": { "enabled": true }, "openclaw-weixin": { "enabled": true } } },
  "agents": { "defaults": { "model": { "primary": "deepseek/deepseek-v4-flash" }, "reasoningDefault": "off", "thinkingDefault": "off" } },
  "meta": { "lastTouchedVersion": "2026.6.11" },
  "wizard": { "lastRunVersion": "2026.6.11" }
}
JSONEOF
log "openclaw.json written; token=${TOKEN:0:8}...${TOKEN: -4}"

cat > ~/.config/systemd/user/openclaw-gateway.service << UNITEOF
[Unit]
Description=OpenClaw Gateway (v2026.6.11)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/ubuntu/openclaw
ExecStart=/usr/bin/node /home/ubuntu/openclaw/dist/index.js gateway --port 18789
Restart=always
RestartSec=5
RestartPreventExitStatus=78
Environment=HOME=/home/ubuntu
Environment=TMPDIR=/tmp
Environment=PATH=/usr/bin:/usr/local/bin:/bin:/home/ubuntu/.npm-global/bin:/home/ubuntu/.local/share/pnpm/bin:/home/ubuntu/.local/bin
Environment=OPENCLAW_GATEWAY_PORT=18789
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
Environment=DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
Environment=OPENAI_API_KEY=${DEEPSEEK_API_KEY}
Environment=OPENAI_BASE_URL=https://api.deepseek.com
Environment=OPENCLAW_ALLOW_OLDER_BINARY_DESTRUCTIVE_ACTIONS=1

[Install]
WantedBy=default.target
UNITEOF
log "systemd unit written: ~/.config/systemd/user/openclaw-gateway.service"

grep -q npm-global ~/.bashrc 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"' >> ~/.bashrc

# 9. Start gateway
step "9/10 Start Gateway"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
log "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
log "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}"

if [ ! -d "${XDG_RUNTIME_DIR}" ]; then
  log "WARN: ${XDG_RUNTIME_DIR} missing — enabling linger and waiting"
fi
sudo loginctl enable-linger ubuntu 2>/dev/null || log "WARN: enable-linger failed"
# linger 后有时需要等 runtime 目录出现
for i in 1 2 3 4 5; do
  if [ -d "${XDG_RUNTIME_DIR}" ]; then break; fi
  log "waiting for ${XDG_RUNTIME_DIR} (${i}/5)..."
  sleep 2
done
[ -d "${XDG_RUNTIME_DIR}" ] || die "XDG_RUNTIME_DIR still missing; cannot start user systemd"

systemctl --user daemon-reload
systemctl --user reset-failed openclaw-gateway 2>/dev/null || true
systemctl --user enable openclaw-gateway 2>/dev/null || true
log "starting openclaw-gateway..."
systemctl --user start openclaw-gateway || {
  log "systemctl --user start failed"
  systemctl --user status openclaw-gateway --no-pager -l || true
  journalctl --user -u openclaw-gateway -n 50 --no-pager || true
  die "failed to start openclaw-gateway"
}

HEALTH="FAIL"
for i in 1 2 3 4 5 6; do
  sleep 5
  HEALTH=$(curl -s -m 5 http://127.0.0.1:18789/health 2>/dev/null || echo "FAIL")
  log "health check ${i}/6: ${HEALTH}"
  if echo "$HEALTH" | grep -q '"ok":true\|"ok"[[:space:]]*:[[:space:]]*true\|ok.*true'; then
    break
  fi
done

if ! echo "$HEALTH" | grep -qi 'ok.*true'; then
  log "Gateway NOT healthy"
  systemctl --user status openclaw-gateway --no-pager -l || true
  journalctl --user -u openclaw-gateway -n 80 --no-pager || true
  die "Gateway health failed: ${HEALTH}"
fi
log "Gateway LIVE"

# 10. Register
step "10/10 Register to hot pool"
PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null \
  || curl -s --connect-timeout 5 ip.sb 2>/dev/null \
  || echo "${IP}")
log "register IP=${PUBLIC_IP} provider=${AGENT_PROVIDER} api=${ADMIN_API}"
if [ ! -f /tmp/register-agent.py ]; then
  log "register-agent.py missing in /tmp, downloading..."
  curl -fL "${DS}/register-agent.py" -o /tmp/register-agent.py || die "cannot download register-agent.py"
fi
set +e
REGISTER_LOCAL=1 python3 /tmp/register-agent.py "$ADMIN_API_KEY" "$PUBLIC_IP" "$AGENT_PROVIDER"
REG_RC=$?
set -e
if [ "$REG_RC" -eq 0 ]; then
  log "Register OK"
else
  log "Register failed (rc=${REG_RC}) — non-fatal; patrol can retry later"
fi

step "DEPLOY COMPLETE"
log "Gateway: http://${PUBLIC_IP}:18789"
log "Token:   ${TOKEN:0:8}...${TOKEN: -4}"
log "Health:  ${HEALTH}"
