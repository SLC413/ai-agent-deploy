#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# quick-deploy.sh — 推送 systemd 服务 + 启动
# 用法: ./quick-deploy.sh <IP> <SSH_KEY> <DEEPSEEK_KEY> [REGION]
#
# 环境变量（可选，有默认值）：
#   DEPLOY_SERVER   - 部署文件托管地址（默认 http://43.160.245.20:9900）
#   ADMIN_API       - 管理平台 API（默认 https://ai.nika8.com/api）
#   ADMIN_EMAIL     - 管理员邮箱（默认从环境变量读取）
#   ADMIN_PASSWORD  - 管理员密码（默认从环境变量读取）
# ============================================================

IP="${1:?需要 IP}"
SSH_KEY="${2:?需要 SSH_KEY}"
DEEPSEEK_KEY="${3:?需要 DEEPSEEK_API_KEY}"
REGION="${4:-Singapore}"

DEPLOY_SERVER="${DEPLOY_SERVER:-http://43.160.245.20:9900}"
ADMIN_API="${ADMIN_API:-https://ai.nika8.com/api}"

# 敏感信息必须从环境变量传入，不允许硬编码
if [ -z "${ADMIN_EMAIL:-}" ]; then
  echo "❌ 请设置环境变量 ADMIN_EMAIL"
  exit 1
fi
if [ -z "${ADMIN_PASSWORD:-}" ]; then
  echo "❌ 请设置环境变量 ADMIN_PASSWORD"
  exit 1
fi

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
Environment=ADMIN_EMAIL=${ADMIN_EMAIL}
Environment=ADMIN_PASSWORD=${ADMIN_PASSWORD}
Environment=DEEPSEEK_API_KEY=${DEEPSEEK_KEY}
Environment=AGENT_REGION=${REGION}
Environment=AGENT_PROVIDER=Tencent

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
