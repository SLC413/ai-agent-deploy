#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# quick-deploy.sh — 一键部署 OpenClaw Agent 到 VPS
# 用法: ./quick-deploy.sh --ssh-key <path> --api-key <key> --ip <ip> --admin-api <url> \
#           [--apitoken <token>] [--ssh-user <user>] [--deploy-server <url>] [--llm-base-url <url>]
#
# 必需参数：
#   --ssh-key          SSH 私钥路径
#   --api-key          管理平台 API 鉴权密钥
#   --ip               目标 VPS IP
#   --admin-api        管理平台 API 地址（例：https://ai.xhl413.com/api）
#
# 可选参数：
#   --apitoken         API Token（不传则自动从算力平台创建账号）
#   --ssh-user         SSH 用户名（默认 ubuntu）
#   --deploy-server    部署脚本下载源（默认 http://43.160.245.20:9900）
#                      国内机器建议用 http://114.55.227.23:9900
#   --llm-base-url     LLM Base URL（默认 https://api.deepseek.com）
#                      用算力平台 Key 时传 https://ai.suanli413.com
# ============================================================

# --- Parse named arguments ---
API_TOKEN=""
SSH_KEY=""
API_KEY=""
IP=""
ADMIN_API=""
SSH_USER="ubuntu"
DEPLOY_SERVER="http://43.160.245.20:9900"
LLM_BASE_URL="https://api.deepseek.com"
AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"

usage() {
  echo "用法: $0 --ssh-key <path> --api-key <key> --ip <ip> --admin-api <url>"
  echo "            [--apitoken <token>] [--ssh-user <user>] [--deploy-server <url>] [--llm-base-url <url>]"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-key)       SSH_KEY="${2:?--ssh-key requires a value}"; shift 2 ;;
    --api-key)       API_KEY="${2:?--api-key requires a value}"; shift 2 ;;
    --apitoken)      API_TOKEN="${2:?--apitoken requires a value}"; shift 2 ;;
    --ip)            IP="${2:?--ip requires a value}"; shift 2 ;;
    --admin-api)     ADMIN_API="${2:?--admin-api requires a value}"; shift 2 ;;
    --ssh-user)      SSH_USER="${2:?--ssh-user requires a value}"; shift 2 ;;
    --deploy-server) DEPLOY_SERVER="${2:?--deploy-server requires a value}"; shift 2 ;;
    --llm-base-url)  LLM_BASE_URL="${2:?--llm-base-url requires a value}"; shift 2 ;;
    -h|--help)       usage ;;
    *) echo "❌ 未知参数: $1"; usage ;;
  esac
done

# Validate required args
[ -n "${SSH_KEY}" ]   || { echo "❌ --ssh-key is required"; usage; }
[ -n "${API_KEY}" ]   || { echo "❌ --api-key is required"; usage; }
[ -n "${IP}" ]        || { echo "❌ --ip is required"; usage; }
[ -n "${ADMIN_API}" ] || { echo "❌ --admin-api is required"; usage; }

SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${IP}"

[ -f "${SSH_KEY}" ] || { echo "❌ SSH_KEY 不存在: ${SSH_KEY}"; exit 1; }

echo "=========================================="
echo " quick-deploy"
echo "  IP:            ${IP}"
echo "  DEPLOY_SERVER: ${DEPLOY_SERVER}"
echo "  ADMIN_API:     ${ADMIN_API}"
echo "  PROVIDER:      ${AGENT_PROVIDER}"
echo "  SSH_KEY:       ${SSH_KEY}"
echo "  LLM_BASE_URL:  ${LLM_BASE_URL}"
if [ -n "${API_TOKEN}" ]; then
  echo "  API_TOKEN:     ${API_TOKEN:0:8}...${API_TOKEN: -4}"
else
  echo "  API_TOKEN:     (will create from suanli413)"
fi
echo "=========================================="

echo "[1/2] SSH 连通性检查..."
# 格式化重装后 host key 会变，先清除旧指纹
ssh-keygen -R "${IP}" 2>/dev/null || true
${SSH} 'echo OK $(hostname) $(whoami)' || { echo "❌ SSH 失败"; exit 1; }

echo "[2/2] 派发 deploy-agent.service ..."

cat > /tmp/deploy-${IP}.service << EOF
[Unit]
Description=OpenClaw Agent Auto-Deploy + HotPool Register
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
User=${SSH_USER}
WorkingDirectory=/tmp

Environment=DEPLOY_SERVER=${DEPLOY_SERVER}
Environment=ADMIN_API=${ADMIN_API}
Environment=ADMIN_API_KEY=${API_KEY}
Environment=API_TOKEN=${API_TOKEN}
Environment=DEEPSEEK_API_KEY=${API_TOKEN}
Environment=LLM_BASE_URL=${LLM_BASE_URL}
Environment=AGENT_PROVIDER=${AGENT_PROVIDER}
Environment=SUANLI_ADMIN_KEY=ak-2b86a45f0af50d35067601ad61d8e153f53eb2b832cab396

ExecStart=/bin/bash -c 'curl -sL \${DEPLOY_SERVER}/register-agent.py -o /tmp/register-agent.py && curl -sL \${DEPLOY_SERVER}/deploy-and-register.sh -o /tmp/deploy-and-register.sh && bash /tmp/deploy-and-register.sh'

StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

scp -q -i ${SSH_KEY} -o StrictHostKeyChecking=no /tmp/deploy-${IP}.service ${SSH_USER}@${IP}:/tmp/deploy-agent.service
${SSH} 'sudo mv /tmp/deploy-agent.service /etc/systemd/system/deploy-agent.service && sudo systemctl daemon-reload && sudo systemctl reset-failed deploy-agent.service 2>/dev/null; sudo systemctl start --no-block deploy-agent.service && systemctl is-active deploy-agent.service'
rm -f /tmp/deploy-${IP}.service

echo ""
echo "✅ ${IP} 已派发 — 目标机正在自动部署+注册，可以继续下一个"
echo "   查看日志: ssh -i ${SSH_KEY} ${SSH_USER}@${IP} 'sudo journalctl -u deploy-agent -f'"

# 记录到跟踪文件（供 patrol-register.sh 补注册）
python3 -c "
import json, time
t = '/tmp/deploy-tracker.json'
try:
    d = json.load(open(t))
except:
    d = []
d.append({'ip':'${IP}','provider':'${AGENT_PROVIDER}','status':'deploying','deploy_at':int(time.time())})
json.dump(d, open(t,'w'))
print('📝 已记录')
"
