#!/usr/bin/env bash
set -euo pipefail

IP="$1"
EMAIL="$2"
PASSWORD="$3"
REGION="${4:-Singapore}"
PROVIDER="${5:-Tencent}"
API="${ADMIN_API:-https://www.nika8.com/api}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/agent01_tencent}"

if [ -z "${IP:-}" ] || [ -z "${EMAIL:-}" ] || [ -z "${PASSWORD:-}" ]; then
  echo "用法: ./register-agent.sh <IP> <EMAIL> <PASSWORD> [REGION] [PROVIDER]"
  echo "可选环境变量: SSH_KEY ADMIN_API"
  exit 1
fi

echo "[register] 读取 $IP 的 Gateway Token..."

# 从远程 VPS 读取 Gateway Token
TOKEN=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$IP" \
  "python3 -c \"import json; print(json.load(open('\\\$HOME/.openclaw/openclaw.json'))['gateway']['auth']['token'])\"" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "❌ 无法读取 Gateway Token，VPS 可能未部署 OpenClaw"
  exit 1
fi
echo "[register] Token: ${TOKEN:0:8}...${TOKEN: -4}"

# 用 Python 处理 JSON（避免 shell 转义问题）
export REG_IP="$IP" REG_EMAIL="$EMAIL" REG_PASSWORD="$PASSWORD"
export REG_REGION="$REGION" REG_PROVIDER="$PROVIDER" REG_API="$API"
export REG_TOKEN="$TOKEN"

python3 << 'PYEOF'
import json, subprocess, os

ip = os.environ['REG_IP']
token = os.environ['REG_TOKEN']
api = os.environ['REG_API']
region = os.environ['REG_REGION']
provider = os.environ['REG_PROVIDER']

# Login
print(f'[register] 登录 {api} ...')
r = subprocess.run([
    'curl', '-s', '-X', 'POST', f'{api}/auth/login',
    '-H', 'Content-Type: application/json',
    '-d', json.dumps({
        'email': os.environ['REG_EMAIL'],
        'password': os.environ['REG_PASSWORD']
    })
], capture_output=True, text=True, timeout=15)

resp = json.loads(r.stdout)
admin_token = resp.get('data', {}).get('token', '')
if not admin_token:
    print(f'❌ 登录失败: {r.stdout[:200]}')
    exit(1)
print('[register] 登录成功')

# Register
gw_url = f'http://{ip}:18789'
print(f'[register] 注册 {gw_url} ...')
r = subprocess.run([
    'curl', '-s', '-X', 'POST', f'{api}/admin/agents',
    '-H', 'Content-Type: application/json',
    '-H', f'Authorization: Bearer {admin_token}',
    '-d', json.dumps({
        'openclawBaseUrl': gw_url,
        'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': token,
        'serverIp': ip,
        'serverRegion': region,
        'serverProvider': provider,
        'skipConnectivityCheck': True
    })
], capture_output=True, text=True, timeout=30)

resp = json.loads(r.stdout)
agent_id = resp.get('data', {}).get('id', 0)
if agent_id:
    print(f'✅ 注册成功: Agent #{agent_id}')
else:
    err = resp.get('error', '')
    if 'already' in str(err).lower():
        print(f'⚠️  已注册')
    else:
        print(f'❌ 注册失败: {r.stdout[:200]}')
        exit(1)
PYEOF
