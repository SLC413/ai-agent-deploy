#!/usr/bin/env bash
set -euo pipefail

API_KEY="$1"
PROVIDER="${2:-Tencent}"
REGION="${3:-Singapore}"
IP="$4"
API="${ADMIN_API:-https://www.nika8.com/api}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/agent01_tencent}"

if [ -z "${API_KEY:-}" ] || [ -z "${IP:-}" ]; then
  echo "用法: ./register-agent.sh <API_KEY> [PROVIDER] [REGION] <IP>"
  echo ""
  echo "获取 API Key: https://www.nika8.com/admin → API 密钥管理"
  exit 1
fi

echo "[register] 读取 $IP 的 Gateway Token..."
TOKEN=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$IP" \
  "python3 -c 'import json; print(json.load(open(\"/home/ubuntu/.openclaw/openclaw.json\"))[\"gateway\"][\"auth\"][\"token\"])'" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "❌ 无法读取 Gateway Token，VPS 可能未部署 OpenClaw"
  exit 1
fi
echo "[register] Token: ${TOKEN:0:8}...${TOKEN: -4}"

export REG_IP="$IP" REG_TOKEN="$TOKEN" REG_REGION="$REGION" REG_PROVIDER="$PROVIDER" REG_API="$API" REG_API_KEY="$API_KEY"

python3 << 'PYEOF'
import json, subprocess, os

ip = os.environ['REG_IP']
token = os.environ['REG_TOKEN']
api = os.environ['REG_API']
api_key = os.environ['REG_API_KEY']
region = os.environ.get('REG_REGION', 'Singapore')
provider = os.environ.get('REG_PROVIDER', 'Tencent')

gw_url = f'http://{ip}:18789'
print(f'[register] 注册 {gw_url} ...')

r = subprocess.run(['curl', '-s', '-X', 'POST', f'{api}/admin/agents',
    '-H', 'Content-Type: application/json',
    '-H', f'Authorization: Bearer {api_key}',
    '-d', json.dumps({
        'openclawBaseUrl': gw_url, 'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': token, 'serverIp': ip,
        'serverRegion': region, 'serverProvider': provider,
        'skipConnectivityCheck': True
    })],
    capture_output=True, text=True, timeout=30)

resp = json.loads(r.stdout)
agent_id = resp.get('data', {}).get('id', 0)
if agent_id:
    print(f'✅ 注册成功: Agent #{agent_id}')
elif 'already' in str(resp.get('error', '')).lower():
    print('⚠️  已注册')
else:
    print(f'❌ 注册失败: {r.stdout[:300]}')
    exit(1)
PYEOF
