#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# quick-deploy.sh — 一键部署 OpenClaw Agent 到 VPS
# 用法: ./quick-deploy.sh <SSH_KEY> <API_KEY> <API_TOKEN> <IP> <ADMIN_API> [SSH_USER] [DEPLOY_SERVER] [LLM_BASE_URL]
#       第3个参数：API_TOKEN，可以是 DeepSeek 原生 Key（sk-...）或算力平台 Key（sk-xxx）
#       第6个参数指定 SSH 用户，默认 ubuntu
#       第7个参数指定部署服务器地址，默认 http://43.160.245.20:9900（海外新加坡，适合新/港/日机器）
#       国内机器请传 http://114.55.227.23:9900（小火龙）
#       第8个参数指定 LLM Base URL，可选。不传默认 https://api.deepseek.com
#       传算力平台 Key 时请传 https://ai.suanli413.com
# ============================================================

SSH_KEY="${1:?需要 SSH_KEY}"
API_KEY="${2:?需要 API_KEY}"
API_TOKEN="${3:?需要 API_TOKEN（DeepSeek Key 或算力平台 Key）}"
IP="${4:?需要 IP}"

ADMIN_API="${5:?需要 ADMIN_API (e.g. https://ai.xhl413.com/api)}"
SSH_USER="${6:-ubuntu}"
DEPLOY_SERVER="${7:-http://43.160.245.20:9900}"
LLM_BASE_URL="${8:-https://api.deepseek.com}"
AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"
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
echo "  API_TOKEN:     ${API_TOKEN:0:8}...${API_TOKEN: -4}"
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
