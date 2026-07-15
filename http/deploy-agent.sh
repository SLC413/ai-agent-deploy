#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenClaw Agent 一键部署 v3
# 用法: ./deploy-agent.sh <IP> <SSH_KEY> <DEEPSEEK_API_KEY> [NAME]
#
# 策略: 基线(v2026.6.11, 预构建) → Onboarding → 修配置 → 初始化 → 启动
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

IP="${1:?缺少 IP}"
SSH_KEY="${2:?缺少 SSH 私钥路径}"
DEEPSEEK_KEY="${3:?缺少 DeepSeek API Key}"
NAME="${4:-agent-${IP##*.}}"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${IP}"
BASELINE="/home/ubuntu/ai-agent-deploy/openclaw-baseline.tar.gz"
SCRIPT_URL="https://raw.githubusercontent.com/BIDXOM/setup-openclaw-ubuntu/refs/heads/main/setup-openclaw-ubuntu.sh"

echo -e "\n=========================================="
echo "  OpenClaw Agent 部署 v3"
echo "  目标: ${IP}  (${NAME})"
echo "==========================================\n"

# ═══ 0. PREFLIGHT ═══
log "0. 前置检查"
${SSH} 'hostname' &>/dev/null || err "SSH 连接失败: ${IP}"
log "   SSH OK"

API_RESP=$(curl -s -m 10 https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer ${DEEPSEEK_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":2}')
echo "$API_RESP" | grep -q '"choices"' || err "DeepSeek Key 无效！${API_RESP}"
log "   Key 有效 ✅"

[ -f "${BASELINE}" ] || err "基线包不存在: ${BASELINE}"
log "   基线: $(ls -lh ${BASELINE} | awk '{print $5}')"

# ═══ 1. PUSH BASELINE ═══
log "1. 推送源码"
${SSH} 'sudo rm -rf /home/ubuntu/openclaw ~/.openclaw 2>/dev/null; mkdir -p /home/ubuntu/openclaw'
cat ${BASELINE} | ${SSH} 'tar xzf - -C /home/ubuntu/openclaw'
${SSH} 'cd ~/openclaw && git init && git remote add origin https://github.com/openclaw/openclaw.git' 2>/dev/null
log "   已部署"

# ═══ 2. INJECT .NPMRC (国内镜像加速) ═══
log "2. 检测网络 + 优化..."
NPM_LATENCY=$(${SSH} 'curl -s -o /dev/null -w "%{time_total}" --connect-timeout 5 https://registry.npmjs.org 2>/dev/null || echo 99')
MATRIX_BIN="/home/ubuntu/ai-agent-deploy/binaries/matrix-sdk-crypto.linux-x64-gnu.node"

if [ "$(echo "${NPM_LATENCY} > 2" | bc -l 2>/dev/null || echo 0)" = "1" ] || [ "${NPM_LATENCY%%.*}" -ge 2 ]; then
  warn "   npmjs 延迟 ${NPM_LATENCY}s → 启用 npmmirror 镜像"
  ${SSH} 'cat > ~/openclaw/.npmrc << NPMRC
registry=https://registry.npmmirror.com
NPMRC'
  # 预推送 matrix-sdk 二进制（GitHub 在国内极慢）
  if [ -f "${MATRIX_BIN}" ]; then
    scp -q -i ${SSH_KEY} -o StrictHostKeyChecking=no "${MATRIX_BIN}" ubuntu@${IP}:/tmp/matrix-sdk-crypto.linux-x64-gnu.node 2>/dev/null || true
    ${SSH} 'mkdir -p ~/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs && cp /tmp/matrix-sdk-crypto.linux-x64-gnu.node ~/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/ && chmod 444 ~/openclaw/node_modules/@matrix-org/matrix-sdk-crypto-nodejs/matrix-sdk-crypto.linux-x64-gnu.node' 2>/dev/null || true
    log "   matrix-sdk 二进制已预置(只读)"
  fi
  # 推送本地缓存的部署脚本；缺失则回退 GitHub
  LOCAL_SCRIPT="/home/ubuntu/ai-agent-deploy/http/setup-openclaw-ubuntu.sh"
  if [ -f "${LOCAL_SCRIPT}" ]; then
    scp -q -i ${SSH_KEY} -o StrictHostKeyChecking=no "${LOCAL_SCRIPT}" ubuntu@${IP}:/tmp/setup-openclaw.sh 2>/dev/null || true
  fi
  if ${SSH} 'test -s /tmp/setup-openclaw.sh' 2>/dev/null; then
    USE_LOCAL_SCRIPT="bash /tmp/setup-openclaw.sh"
  else
    warn "   本地 setup 脚本不可用，回退 GitHub"
    USE_LOCAL_SCRIPT="bash <(curl -sL ${SCRIPT_URL})"
  fi
else
  log "   npmjs 延迟 ${NPM_LATENCY}s，无需镜像"
  USE_LOCAL_SCRIPT="bash <(curl -sL ${SCRIPT_URL})"
fi

# ═══ 3. ONBOARDING ═══
log "3. Onboarding (系统依赖 + pnpm install + 初始化)..."
${SSH} "export DEEPSEEK_API_KEY='${DEEPSEEK_KEY}' && ${USE_LOCAL_SCRIPT}" 2>&1 | \
  grep -E "^(==>|OpenClaw|Gateway|服务器|✅|部署完成|================================)" || true

sleep 3
${SSH} 'pkill -f "openclaw onboard" 2>/dev/null' || true
sleep 2
log "   Onboarding 完成"

# ═══ 4. FIX CONFIG ═══
log "4. 修复配置..."
${SSH} '
# pnpm
[ ! -f ~/.local/share/pnpm/bin/pnpm ] && ln -sf ~/.npm-global/bin/pnpm ~/.local/share/pnpm/bin/pnpm

# node-pty
cd ~/openclaw && CI=true ~/.npm-global/bin/pnpm approve-builds node-pty 2>/dev/null || true

# systemd PATH
S=~/.config/systemd/user/openclaw-gateway.service
if [ -f "$S" ] && ! grep -q "npm-global/bin" "$S"; then
  sed -i "s|Environment=PATH=.*|Environment=PATH=/usr/bin:/usr/local/bin:/bin:/home/ubuntu/.npm-global/bin:/home/ubuntu/.local/share/pnpm/bin:/home/ubuntu/.local/bin:/home/ubuntu/bin|" "$S"
fi

# API Key
if [ -f "$S" ]; then
  sed -i "/^\[Service\]/a Environment=DEEPSEEK_API_KEY='"${DEEPSEEK_KEY}"'" "$S" 2>/dev/null || true
  sed -i "/^\[Service\]/a Environment=OPENAI_API_KEY='"${DEEPSEEK_KEY}"'" "$S" 2>/dev/null || true
  sed -i "/^\[Service\]/a Environment=OPENAI_BASE_URL=https://api.deepseek.com" "$S" 2>/dev/null || true
fi

# 创建 openclaw wrapper
cat > ~/.local/bin/openclaw << '\''WRAPPER'\''
#!/usr/bin/env bash
cd "$HOME/openclaw" || exit 1
exec "$HOME/.npm-global/bin/pnpm" openclaw "$@"
WRAPPER
chmod +x ~/.local/bin/openclaw

# 修复 PATH
grep -q "npm-global" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$HOME/.npm-global/bin:\$PATH\"" >> ~/.bashrc
grep -q "PNPM_HOME" ~/.bashrc || echo "export PNPM_HOME=\"\$HOME/.local/share/pnpm/bin\"" >> ~/.bashrc
echo "export PATH=\"\$PNPM_HOME:\$PATH\"" >> ~/.bashrc
'
log "   已修复"

# ═══ 5. INIT GATEWAY (disable reasoning + enable endpoints) ═══
log "5. 初始化 Gateway (禁用 reasoning + 启用 API 端点)..."
${SSH} '
# 禁用 DeepSeek V4 reasoning/thinking
cd ~/openclaw
~/.npm-global/bin/pnpm openclaw config set agents.defaults.reasoningDefault off 2>/dev/null || true
~/.npm-global/bin/pnpm openclaw config set agents.defaults.thinkingDefault off 2>/dev/null || true

# 启用 admin-http-rpc 插件
~/.npm-global/bin/pnpm openclaw plugins enable admin-http-rpc 2>/dev/null || true

# 启用 OpenAI Chat Completions API
~/.npm-global/bin/pnpm openclaw config patch --raw """{
  "gateway": {
    "http": {
      "endpoints": {
        "chatCompletions": {
          "enabled": true
        }
      }
    }
  }
}""" 2>/dev/null || true

# 锁定 meta 版本
python3 << """PYEOF"""
import json, os
cfg_path = os.path.expanduser("~/.openclaw/openclaw.json")
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        cfg = json.load(f)
    cfg.setdefault("meta", {})["lastTouchedVersion"] = "2026.6.11"
    cfg.setdefault("wizard", {})["lastRunVersion"] = "2026.6.11"
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
PYEOF

log "   初始化完成 ✅"
'

# ═══ 6. CLEAN & START ═══
log "6. 启动 Gateway..."
${SSH} '
  rm -f ~/.openclaw/state/openclaw.sqlite* ~/.openclaw/logs/stability/*.json 2>/dev/null
  systemctl --user daemon-reload
  systemctl --user reset-failed openclaw-gateway 2>/dev/null || true
  systemctl --user start openclaw-gateway
'
log "   等待就绪..."

# ═══ 7. VERIFY ═══
log "7. 验证..."
for i in 1 2 3; do
  sleep 10
  HEALTH=$(${SSH} 'curl -s -m 5 http://127.0.0.1:18789/health 2>/dev/null' || echo "")
  if echo "$HEALTH" | grep -q '"ok":true'; then
    log "   ✅ ${HEALTH}"
    break
  fi
  warn "   第 ${i} 次重试..."
done

if ! echo "${HEALTH:-}" | grep -q '"ok":true'; then
  err "   ❌ Gateway 未就绪: ${HEALTH:-已超时}"
fi

# ═══ DONE ═══
# Token is shown in Onboarding output above

echo -e "\n=========================================="
echo "  ✅ ${NAME} 部署成功"
echo "=========================================="
echo "  IP:        ${IP}"
echo "  Gateway:   http://${IP}:18789"
echo "  Token:     见上方 Onboarding 输出"
echo ""
