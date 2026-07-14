#!/usr/bin/env bash
# ============================================================
# register-agent.sh — 手动注册智能体到管理平台
# 用法: ./register-agent.sh <API_KEY> <IP> [PROVIDER]
# ============================================================
export REG_API_KEY="$1"
export REG_IP="$2"
export REG_PROVIDER="${3:-Tencent}"
export REG_API="${ADMIN_API:-https://www.nika8.com/api}"
export REG_SSH_KEY="${SSH_KEY:-~/.ss…nt}"

if [ -z "${REG_API_KEY:-}" ] || [ -z "${REG_IP:-}" ]; then
  echo "用法: ./register-agent.sh <API_KEY> <IP> [PROVIDER]"
  exit 1
fi

python3 << 'PYEOF'
import json, subprocess, os

api_key = os.environ['REG_API_KEY']
ip = os.environ['REG_IP']
provider = os.environ['REG_PROVIDER']
api = os.environ['REG_API']
ssh_key = os.path.expanduser(os.environ['REG_SSH_KEY'])

print(f'[register] 读取 {ip} 的 Gateway Token...')
r = subprocess.run([
    'ssh', '-i', ssh_key, '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10',
    f'ubuntu@{ip}',
    'python3', '-c', 'import json; print(json.load(open("/home/ubuntu/.openclaw/openclaw.json"))["gateway"]["auth"]["token"])'
], capture_output=True, text=True, timeout=15)

gw_token = r.stdout.strip()
if not gw_token:
    print(f'❌ 无法读取 Gateway Token: {r.stderr[:200]}')
    exit(1)
print(f'[register] Token: {gw_token[:8]}...{gw_token[-4:]}')

gw_url = f'http://{ip}:18789'
print(f'[register] 注册 {gw_url} ...')

r = subprocess.run([
    'curl', '-s', '-X', 'POST', f'{api}/admin/agents',
    '-H', 'Content-Type: application/json',
    '-H', f'Authorization: Bearer {api_key}',
    '-d', json.dumps({
        'openclawBaseUrl': gw_url,
        'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': gw_token,
        'serverIp': ip,
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
        print('⚠️  已注册')
    else:
        print(f'❌ 注册失败: {r.stdout[:300]}')
        exit(1)
PYEOF
