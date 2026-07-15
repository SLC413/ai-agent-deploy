#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# quick-deploy.sh — 一键部署 OpenClaw Agent 到 VPS
# 用法: ./quick-deploy.sh <SSH_KEY> <API_KEY> <DEEPSEEK_KEY> <IP>
# ============================================================

SSH_KEY="${1:?需要 SSH_KEY}"
API_KEY="${2:?需要 API_KEY}"
DEEPSEEK_KEY="${3:?需要 DEEPSEEK_API_KEY}"
IP="${4:?需要 IP}"

DEPLOY_SERVER="${DEPLOY_SERVER:-http://43.160.245.20:9900}"
ADMIN_API="${ADMIN_API:-https://www.nika8.com/api}"
AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ubuntu@${IP}"

echo "Pushing deploy service to ${IP}..."

cat > /tmp/deploy-${IP}.service << EOF
[Unit]
Description=OpenClaw Agent Auto-Deploy + HotPool Register
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
User=ubuntu
WorkingDirectory=/tmp

Environment=DEPLOY_SERVER=${DEPLOY_SERVER}
Environment=ADMIN_API=${ADMIN_API}
Environment=ADMIN_API_KEY=${API_KEY}
Environment=DEEPSEEK_API_KEY=${DEEPSEEK_KEY}
Environment=AGENT_PROVIDER=${AGENT_PROVIDER}

ExecStart=/bin/bash -c 'curl -sL \${DEPLOY_SERVER}/register-agent.py -o /tmp/register-agent.py && curl -sL \${DEPLOY_SERVER}/deploy-and-register.sh -o /tmp/deploy-and-register.sh && bash /tmp/deploy-and-register.sh'

StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

scp -q -i ${SSH_KEY} -o StrictHostKeyChecking=no /tmp/deploy-${IP}.service ubuntu@${IP}:/tmp/deploy-agent.service
${SSH} 'sudo mv /tmp/deploy-agent.service /etc/systemd/system/deploy-agent.service && sudo systemctl daemon-reload && sudo systemctl start deploy-agent.service'
rm /tmp/deploy-${IP}.service

echo ""
echo "✅ 已启动 — 服务会自动完成部署+注册"
echo "查看日志: ssh -i ${SSH_KEY} ubuntu@${IP} 'sudo journalctl -u deploy-agent -f'"

# 记录部署到跟踪文件（供 patrol-register.sh 补注册）
python3 << PYEOF
import json, time
tracker_file = '/tmp/deploy-tracker.json'
record = {
    'ip': '${IP}',
    'provider': '${AGENT_PROVIDER}',
    'status': 'deploying',
    'deploy_at': int(time.time())
}
try:
    tracker = json.load(open(tracker_file))
except Exception:
    tracker = []
tracker.append(record)
json.dump(tracker, open(tracker_file, 'w'), ensure_ascii=False, indent=2)
print("📝 部署记录已写入 (30分钟后自动验证注册)")
PYEOF
