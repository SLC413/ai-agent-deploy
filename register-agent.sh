#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# register-agent.sh — 手动注册智能体到管理平台
# 用法: ./register-agent.sh <API_KEY> <IP>
# ============================================================

API_KEY="***"
IP="$2"
API="${ADMIN_API:-https://www.nika8.com/api}"
SSH_KEY="${SSH_…ent}"

if [ -z "${API_KEY:-}" ] || [ -z "${IP:-}" ]; then
  echo "用法: ./register-agent.sh <API_KEY> <IP>"
  echo "获取 API Key: https://www.nika8.com/admin → API 密钥"
  exit 1
fi

echo "[register] 读取 ${IP} 的 Gateway Token..."
TOKEN=*** -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$IP" \
  "python3 -c 'import json; print(json.load(open(\"/home/ubuntu/.openclaw/openclaw.json\"))[\"gateway\"][\"auth\"][\"token\"])'" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "❌ 无法读取 Gateway Token"
  exit 1
fi
echo "[register] Token: ${TOKEN:*** -4}"

export REG_IP="$IP" REG_TOKEN="***" REG_API="$API" REG_API_KEY="***"

python3 << 'PYEOF'
import json, subprocess, os
ip = os.environ['REG_IP']
token = os.environ['REG_TOKEN']
api = os.environ['REG_API']
api_key = os.environ['REG_API_KEY']

gw_url = f'http://{ip}:18789'
print(f'[register] 注册 {gw_url} ...')

r = subprocess.run(['curl', '-s', '-X', 'POST', f'{api}/admin/agents',
    '-H', 'Content-Type: application/json',
    '-H', f'Authorization: Bearer {api_key}',
    '-d', json.dumps({
        'openclawBaseUrl': gw_url, 'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': token, 'serverIp': ip,
        'serverProvider': 'Tencent', 'skipConnectivityCheck': True
    })],
    capture_output=True, text=True, timeout=30)

resp = json.loads(r.stdout)
agent_id = resp.get('data', {}).get('id', 0)
if agent_id:
    print(f'✅ 注册成功: Agent #{agent_id}')
else:
    err = resp.get('error', '')
    if 'already' in str(err).lower():
        print('⚠️  已注册')
    else:
        print(f'❌ 注册失败: {r.stdout[:300]}')
        exit(1)
PYEOF
