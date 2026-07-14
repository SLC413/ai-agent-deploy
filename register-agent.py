#!/usr/bin/env python3
"""register-agent — Register an OpenClaw agent on the management platform.
Usage: ./register-agent.py <API_KEY> <IP> [PROVIDER]"""
import json, subprocess, os, sys

api_key = sys.argv[1]
ip = sys.argv[2]
provider = sys.argv[3] if len(sys.argv) > 3 else 'Tencent'
api = os.environ.get('ADMIN_API', 'https://www.nika8.com/api')
ssh_key = os.path.expanduser(os.environ.get('SSH_KEY', '~/.ssh/agent01_tencent'))

# 1. Get Gateway Token from remote VPS
print(f'[register] Reading {ip} Gateway Token...')
py_cmd = "import json; print(json.load(open('/home/ubuntu/.openclaw/openclaw.json'))['gateway']['auth']['token'])"
# Use stdin to avoid shell quoting issues
r = subprocess.run(['ssh', '-i', ssh_key, '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10', f'ubuntu@{ip}', 'python3'], input=py_cmd, capture_output=True, text=True, timeout=15)

gw_token = r.stdout.strip()
if not gw_token:
    print(f'FAILED: {r.stderr[:200]}')
    sys.exit(1)
print(f'[register] Token: {gw_token[:8]}...{gw_token[-4:]}')

# 2. Register agent
gw_url = f'http://{ip}:18789'
print(f'[register] Registering {gw_url} ...')
r = subprocess.run([
    'curl', '-s', '-X', 'POST', f'{api}/admin/agents',
    '-H', 'Content-Type: application/json',
    '-H', f'Authorization: Bearer {api_key}',
    '-d', json.dumps({
        'openclawBaseUrl': gw_url, 'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': gw_token, 'serverIp': ip,
        'serverProvider': provider, 'skipConnectivityCheck': True
    })
], capture_output=True, text=True, timeout=30)

resp = json.loads(r.stdout)
agent_id = resp.get('data', {}).get('id', 0)
if agent_id:
    print(f'SUCCESS: Agent #{agent_id}')
else:
    err = resp.get('error', '')
    if 'already' in str(err).lower():
        print('Already registered')
    else:
        print(f'FAILED: {r.stdout[:300]}')
        sys.exit(1)
