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
force_local = os.environ.get('REGISTER_LOCAL', '').lower() in ('1', 'true', 'yes')

print(f'[register] api={api} ip={ip} provider={provider}')
print(f'[register] local_cfg_exists={os.path.exists(local_cfg)} ssh_key_exists={os.path.exists(ssh_key)} force_local={force_local}')

py_cmd = (
    "import json; "
    "print(json.load(open('/home/ubuntu/.openclaw/openclaw.json'))"
    "['gateway']['auth']['token'])"
)

# 优先本机配置（部署机注册）；控制机可用 SSH。REGISTER_LOCAL=1 强制本机。
if force_local or (os.path.exists(local_cfg) and not os.path.exists(ssh_key)):
    print('[register] Reading local Gateway Token...')
    r = subprocess.run(
        ['python3', '-c',
         "import json; print(json.load(open(%r))['gateway']['auth']['token'])" % local_cfg],
        capture_output=True, text=True, timeout=10,
    )
elif os.path.exists(local_cfg):
    # 本机有配置时优先本机（避免控制机误带同名 key 路径时仍优先本地部署场景）
    # 若同时有 SSH key 且本机就是 agent：REGISTER_LOCAL 未设时也读本机
    print('[register] Reading local Gateway Token (local config present)...')
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
    print(f'FAILED: no SSH key ({ssh_key}) and no local config ({local_cfg})')
    sys.exit(1)

gw_token = r.stdout.strip()
if not gw_token:
    print(f'FAILED: empty token; stderr={r.stderr[:300]!r} stdout={r.stdout[:100]!r}')
    sys.exit(1)
print(f'[register] Token: {gw_token[:8]}...{gw_token[-4:]}')

gw_url = f'http://{ip}:18789'
print(f'[register] POST {api}/admin/agents  gateway={gw_url}')
r = subprocess.run([
    'curl', '-s', '-S', '-w', '\nHTTP_CODE:%{http_code}',
    '-X', 'POST', f'{api}/admin/agents',
    '-H', 'Content-Type: application/json',
    '-H', f'Authorization: Bearer {api_key}',
    '-d', json.dumps({
        'openclawBaseUrl': gw_url,
        'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': gw_token,
        'serverIp': ip,
        'serverProvider': provider,
        'skipConnectivityCheck': True,
        'computeEmail': os.environ.get('COMPUTE_EMAIL', ''),
        'computeUserId': int(os.environ.get('COMPUTE_USER_ID', '0') or '0') or None,
    }),
], capture_output=True, text=True, timeout=30)

body = r.stdout
http_code = ''
if 'HTTP_CODE:' in body:
    body, http_code = body.rsplit('HTTP_CODE:', 1)
    http_code = http_code.strip()
print(f'[register] curl_rc={r.returncode} http_code={http_code} body={body[:400]!r}')

try:
    resp = json.loads(body)
except json.JSONDecodeError:
    print(f'FAILED: non-JSON response: {body[:300]}')
    sys.exit(1)

agent_id = resp.get('data', {}).get('id', 0)
if agent_id:
    print(f'SUCCESS: Agent #{agent_id}')
else:
    err = resp.get('error', '')
    if 'already' in str(err).lower():
        print('Already registered')
    else:
        print(f'FAILED: {body[:300]}')
        sys.exit(1)
