#!/usr/bin/env bash
# ============================================================
# deploy-and-register.sh — OpenClaw Agent 部署 + 热池注册
#
# 必需环境变量：
#   ADMIN_API         管理平台 API 基础 URL（例：https://ai.xhl413.com/api）
#   API_TOKEN         API 令牌（DeepSeek Key 或算力平台 Key）
#   ADMIN_API_KEY     管理平台 API 鉴权密钥
#
# 可选环境变量：
#   DEPLOY_SERVER     部署文件下载源（默认 http://43.160.245.20:9900）
#   AGENT_PROVIDER    云服务商标识（默认 Tencent）
#   LLM_BASE_URL      LLM Base URL（默认 https://api.deepseek.com）
#
# 向后兼容：如果只设了 DEEPSEEK_API_KEY 没设 API_TOKEN，自动从 DEEPSEEK_API_KEY 读取
# ============================================================
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
: "${ADMIN_API:?need ADMIN_API (e.g. https://ai.xhl413.com/api)}"
: "${ADMIN_API_KEY:?need ADMIN_API_KEY}"

# API_TOKEN 优先读取，fallback 到 DEEPSEEK_API_KEY 保持向后兼容
API_TOKEN="${API_TOKEN:-${DEEPSEEK_API_KEY:-}}"
: "${API_TOKEN:?need API_TOKEN 或 DEEPSEEK_API_KEY}"

LLM_BASE_URL="${LLM_BASE_URL:-https://api.deepseek.com}"
# Ensure /v1 suffix: OpenClaw appends /chat/completions to baseUrl
[[ "${LLM_BASE_URL}" != */v1 ]] && LLM_BASE_URL="${LLM_BASE_URL%/}/v1"
export AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"
export ADMIN_API API_TOKEN LLM_BASE_URL ADMIN_API_KEY
export CI=true
SSH_USER="$(whoami)"
SSH_HOME="${HOME}"

IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null \
  || curl -s --connect-timeout 5 ip.sb 2>/dev/null \
  || echo unknown)
step "START deploy"
log "Public IP: ${IP}"
log "DEPLOY_SERVER: ${DS}"
log "ADMIN_API: ${ADMIN_API}"
log "AGENT_PROVIDER: ${AGENT_PROVIDER}"
log "LLM_BASE_URL: ${LLM_BASE_URL}"
log "API_TOKEN set: $([ -n "${API_TOKEN}" ] && echo yes || echo no) (len=${#API_TOKEN})"
log "ADMIN_API_KEY set: $([ -n "${ADMIN_API_KEY}" ] && echo yes || echo no) (len=${#ADMIN_API_KEY})"

# 1. Baseline
step "1/10 Download baseline"
# 使用 SSH_HOME 而非硬编码 /home/${USER}，兼容 root（/root）等非常规家目录
sudo rm -rf "${SSH_HOME}/openclaw" "${SSH_HOME}/.openclaw" 2>/dev/null || true
sudo mkdir -p "${SSH_HOME}/openclaw"
log "下载 baseline (~138MB) ..."
if ! curl -# -fL --connect-timeout 30 --max-time 1800 \
    "${DS}/openclaw-baseline.tar.gz" \
    -o /tmp/openclaw-baseline.tar.gz; then
  die "baseline download failed from ${DS}/openclaw-baseline.tar.gz"
fi
log "解压..."
sudo tar xzf /tmp/openclaw-baseline.tar.gz -C "${SSH_HOME}/openclaw"
rm -f /tmp/openclaw-baseline.tar.gz
sudo chown -R "${SSH_USER}:${SSH_USER}" "${SSH_HOME}/openclaw"
[ -f "${SSH_HOME}/openclaw/package.json" ] || die "baseline missing package.json"
log "baseline OK: $(du -sh "${SSH_HOME}/openclaw" | awk '{print $1}')"
log "dist present: $([ -f "${SSH_HOME}/openclaw/dist/index.js" ] && echo yes || echo NO)"
PKG_JSON="${SSH_HOME}/openclaw/package.json"
python3 -c "import json; print('package.json name/version:', json.load(open('${PKG_JSON}')).get('name'), json.load(open('${PKG_JSON}')).get('version'))" 2>/dev/null || true

# 2. System deps
step "2/10 System deps"

# 等待 apt 锁释放（最多等 5 分钟）
for i in $(seq 1 30); do
  if sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    log "等待 apt 锁释放 (${i}/30)..."
    sleep 10
  else
    log "WARN: suanli413 API unreachable, using original API_TOKEN"
    break
  fi
done

# 如果还是锁着的，杀掉 unattended-upgrades
if sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  log "强制释放 apt 锁..."
  sudo kill -9 "$(sudo fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -d ' ')" 2>/dev/null || true
  sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
  sudo dpkg --configure -a 2>/dev/null || true
fi

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
cd "${SSH_HOME}/openclaw"
if [ "${LATENCY%%.*}" -ge 2 ] 2>/dev/null; then
  log "China network - enabling npmmirror"
  echo "registry=https://registry.npmmirror.com" > "${SSH_HOME}/openclaw/.npmrc"
  mkdir -p "${SSH_HOME}/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs"
  if curl -fL --connect-timeout 20 --max-time 120 \
    "${DS}/matrix-sdk-crypto.linux-x64-gnu.node" \
    -o "${SSH_HOME}/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/matrix-sdk-crypto.linux-x64-gnu.node" \
    >/tmp/deploy-step.log 2>&1; then
    log "matrix-sdk binary preloaded"
  else
    log "WARN: suanli413 API unreachable, using original API_TOKEN"
    log "WARN: matrix-sdk binary download failed (non-fatal)"
  fi
else
  log "npmjs OK, no mirror"
  : > "${SSH_HOME}/openclaw/.npmrc"
fi

# 6. Git + patch package.json
step "6/10 Prepare package.json / git"
git init >/dev/null 2>&1 || true
git remote remove origin >/dev/null 2>&1 || true
git remote add origin https://github.com/openclaw/openclaw.git >/dev/null 2>&1 || true
git config --global --add safe.directory "${SSH_HOME}/openclaw" >/dev/null 2>&1 || true
log "git remotes: $(git remote -v 2>/dev/null | tr '\n' ' ' || echo none)"

python3 << PY
import json
from pathlib import Path
BASE = "${SSH_HOME}/openclaw"
p = Path(BASE) / "package.json"
cfg = json.loads(p.read_text())
pnpm_cfg = cfg.setdefault("pnpm", {})
pnpm_cfg["allowUnusedPatches"] = True
pnpm_cfg["allowNonAppliedPatches"] = True

# matrix-sdk-crypto-nodejs 0.6.1+ 支持 MATRIX_SDK_CRYPTO_DOWNLOADS_BASE_URL 环境变量
# baseline 锁了 0.6.0，直接升级 extensions/matrix/package.json 中的精确版本
matrix_pkg = Path(BASE) / "extensions/matrix/package.json"
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

cd "${SSH_HOME}/openclaw"
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

# 7.5 Create suanli413 dedicated account + API key (if SUANLI_ADMIN_KEY is set)
if [ -n "${SUANLI_ADMIN_KEY:-}" ]; then
  step "7.5/10 Create suanli413 account"
  SUANLI_INITIAL_TOKENS="${SUANLI_INITIAL_TOKENS:-30000000000}"
  log "Creating suanli413 account (initial_tokens=${SUANLI_INITIAL_TOKENS})..."
  set +e
  ACCOUNT_RESP=$(curl -s --connect-timeout 10 -X POST https://ai.suanli413.com/api/admin/accounts \
    -H "Authorization: Bearer ${SUANLI_ADMIN_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"label\":\"pool-agent-${IP}\",\"initial_tokens\":${SUANLI_INITIAL_TOKENS}}")
  CURL_RC=$?
  set -e
  if [ "$CURL_RC" -eq 0 ]; then
    NEW_API_KEY=$(echo "${ACCOUNT_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('api_key',{}).get('full_key',''))" 2>/dev/null)
    if [ -n "${NEW_API_KEY}" ]; then
      NEW_EMAIL=$(echo "${ACCOUNT_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user',{}).get('email',''))" 2>/dev/null)
      log "suanli413 account: ${NEW_EMAIL}"
      log "suanli413 API key: ${NEW_API_KEY:0:15}..."
      API_TOKEN="${NEW_API_KEY}"
      LLM_BASE_URL="https://ai.suanli413.com"
    else
      log "WARN: suanli413 account creation returned no key, using original API_TOKEN"
      log "Response (first 300): ${ACCOUNT_RESP:0:300}"
    fi
  else
    log "WARN: suanli413 API unreachable, using original API_TOKEN"
  fi
fi

# 8. Write openclaw.json + systemd unit
step "8/10 Write config + systemd unit"
mkdir -p "${SSH_HOME}/.openclaw" ~/.config/systemd/user ~/.local/bin
TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
cat > "${SSH_HOME}/.openclaw/openclaw.json" << JSONEOF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "auth": { "mode": "token", "token": "${TOKEN}" },
    "http": { "endpoints": { "chatCompletions": { "enabled": true } } }
  },
  "plugins": { "entries": { "admin-http-rpc": { "enabled": true }, "openclaw-weixin": { "enabled": true } } },
  "models": { "providers": { "deepseek": { "apiKey": "${API_TOKEN}", "baseUrl": "${LLM_BASE_URL}" } } },
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
WorkingDirectory=${SSH_HOME}/openclaw
ExecStart=/usr/bin/node ${SSH_HOME}/openclaw/dist/index.js gateway --port 18789
Restart=always
RestartSec=5
RestartPreventExitStatus=78
Environment=HOME=${SSH_HOME}
Environment=TMPDIR=/tmp
Environment=PATH=/usr/bin:/usr/local/bin:/bin:${SSH_HOME}/.npm-global/bin:${SSH_HOME}/.local/share/pnpm/bin:${SSH_HOME}/.local/bin
Environment=OPENCLAW_GATEWAY_PORT=18789
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
Environment=DEEPSEEK_API_KEY=${API_TOKEN}
Environment=OPENAI_API_KEY=${API_TOKEN}
Environment=OPENAI_BASE_URL=${LLM_BASE_URL}
Environment=OPENCLAW_ALLOW_OLDER_BINARY_DESTRUCTIVE_ACTIONS=1

[Install]
WantedBy=default.target
UNITEOF
log "systemd unit written: ~/.config/systemd/user/openclaw-gateway.service"

# 创建 openclaw CLI wrapper + PATH
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"
cat > ~/.local/bin/openclaw << 'WRAPPER'
#!/usr/bin/env bash
cd "$HOME/openclaw" || exit 1
exec "$HOME/.npm-global/bin/pnpm" openclaw "$@"
WRAPPER
chmod +x ~/.local/bin/openclaw
grep -q "npm-global" ~/.bashrc 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$PATH"' >> ~/.bashrc
log "openclaw CLI wrapper created"

# baseline 的 dist 是预构建的，需要修复 build stamp 避免 CLI 触发不必要的重建
# 1. 将所有文件纳入 git（避免 "dirty tree" 触发重建）
cd "${SSH_HOME}/openclaw"
git config user.email "deploy@agent.local" 2>/dev/null || true
git config user.name "Deploy" 2>/dev/null || true
git add -A 2>/dev/null || true
git commit -m "baseline snapshot" 2>/dev/null || true
HEAD=$(git rev-parse HEAD 2>/dev/null || echo "no-commit")
NOW=$(date +%s)000
# 2. 创建/更新 build stamp 文件
echo "{\"builtAt\":$NOW,\"head\":\"$HEAD\"}" > dist/.buildstamp
echo "{\"syncedAt\":$NOW,\"head\":\"$HEAD\"}" > dist/.runtime-postbuildstamp
log "build stamps synced to git HEAD: ${HEAD:0:12}"

# 安装微信插件（渠道配置留给岗前培训，build stamp 已修复，CLI 可正常工作）
export PATH="$HOME/.npm-global/bin:$HOME/.local/share/pnpm/bin:$HOME/.local/bin:$PATH"
npm install @tencent-weixin/openclaw-weixin@latest --no-save --legacy-peer-deps 2>/dev/null || true
~/.npm-global/bin/pnpm openclaw plugins install @tencent-weixin/openclaw-weixin 2>/dev/null && \
  log "weixin plugin installed" || log "WARN: weixin plugin install failed (non-fatal)"

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
sudo loginctl enable-linger "${SSH_USER}" 2>/dev/null || log "WARN: enable-linger failed"
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
