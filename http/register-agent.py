#!/usr/bin/env python3
"""register-agent — Register an OpenClaw agent on the management platform.
Usage: ./register-agent.py <API_KEY> <IP> [PROVIDER]

On the target VPS (no need for SSH): prefers local ~/.openclaw/openclaw.json.
From a control machine: uses SSH_KEY (default ~/.ssh/agent01_tencent) when present.
"""
import json, subprocess, os, sys

api_key = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('ADMIN_API_KEY', '')
ip = sys.argv[2] if len(sys.argv) > 2 else os.environ.get('PUBLIC_IP', '')
if not ip:
    import urllib.request
    for url in ('https://ifconfig.me', 'https://ip.sb', 'https://api.ipify.org'):
        try:
            ip = urllib.request.urlopen(url, timeout=5).read().decode().strip()
            if ip:
                break
        except Exception:
            pass
if not api_key:
    print('FAILED: missing API_KEY (argv[1] or ADMIN_API_KEY)')
    sys.exit(1)
if not ip:
    print('FAILED: missing IP')
    sys.exit(1)

provider = sys.argv[3] if len(sys.argv) > 3 else os.environ.get('AGENT_PROVIDER', 'Tencent')
api = os.environ.get('ADMIN_API', 'https://www.nika8.com/api').rstrip('/')
ssh_key = os.path.expanduser(os.environ.get('SSH_KEY', '~/.ssh/agent01_tencent'))
local_cfg = os.path.expanduser('~/.openclaw/openclaw.json')

py_cmd = (
    "import json; "
    "print(json.load(open('/home/ubuntu/.openclaw/openclaw.json'))"
    "['gateway']['auth']['token'])"
)

# Prefer local config when registering on the agent host itself
if os.path.exists(local_cfg):
    print('[register] Reading local Gateway Token...')
    r = subprocess.run(
        ['python3', '-c',
         "import json; print(json.load(open(%r))['gateway']['auth']['token'])" % local_cfg],
        capture_output=True, text=True, timeout=10,
    )
elif os.path.exists(ssh_key):
    print(f'[register] Reading {ip} Gateway Token via SSH...')
    r = subprocess.run(
        ['ssh', '-i', ssh_key, '-o', 'StrictHostKeyChecking=no',
         '-o', 'ConnectTimeout=10', f'ubuntu@{ip}', 'python3'],
        input=py_cmd, capture_output=True, text=True, timeout=15,
    )
else:
    print(f'FAILED: no local config ({local_cfg}) and no SSH key ({ssh_key})')
    sys.exit(1)

gw_token = r.stdout.strip()
if not gw_token:
    print(f'FAILED: {r.stderr[:200]}')
    sys.exit(1)
print(f'[register] Token: {gw_token[:8]}...{gw_token[-4:]}')

gw_url = f'http://{ip}:18789'
print(f'[register] Registering {gw_url} ...')
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
        'skipConnectivityCheck': True,
    }),
], capture_output=True, text=True, timeout=30)

try:
    resp = json.loads(r.stdout)
except json.JSONDecodeError:
    print(f'FAILED: non-JSON response: {r.stdout[:300]}')
    sys.exit(1)

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
