#!/usr/bin/env python3
import json, sys, os, subprocess

API = os.environ.get("ADMIN_API", "https://www.nika8.com/api")
EMAIL = os.environ.get("ADMIN_EMAIL", "")
PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
API_KEY = os.environ.get("ADMIN_API_KEY", "")
REGION = os.environ.get("AGENT_REGION", "Unknown")
PROVIDER = os.environ.get("AGENT_PROVIDER", "Tencent")
CONFIG = os.environ.get("OPENCLAW_CONFIG", "/home/ubuntu/.openclaw/openclaw.json")

def api_call(method, path, data, token):
    args = ["curl", "-s", "-X", method, API + path, "-H", "Content-Type: application/json"]
    if token:
        args.append("-H")
        args.append("Authorization: Bearer " + token)
    if data:
        args.append("-d")
        args.append(json.dumps(data))
    r = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if r.stdout.strip():
        return json.loads(r.stdout)
    return {"error": r.stderr.strip()}

cfg = json.load(open(CONFIG))
token = cfg["gateway"]["auth"]["token"]
print("[register] Token: " + token[:8] + "..." + token[-4:])

ip = os.environ.get("PUBLIC_IP", "")
if not ip:
    ip = subprocess.run(["curl", "-s", "ifconfig.me"], capture_output=True, text=True).stdout.strip()
    if not ip:
        ip = subprocess.run(["curl", "-s", "ip.sb"], capture_output=True, text=True).stdout.strip()

# Auth: prefer API_KEY, fallback to email/password
auth_token = ""
if API_KEY:
    auth_token = API_KEY
    print("[register] Using API Key")
elif EMAIL and PASSWORD:
    resp = api_call("POST", "/admin/auth/login", {"email": EMAIL, "password": PASSWORD}, None)
    auth_token = resp.get("data", {}).get("token", "")
    if not auth_token:
        print("[register] Login FAILED: " + str(resp))
        sys.exit(1)
    print("[register] Login OK")
else:
    print("[register] No API_KEY or credentials found")
    sys.exit(1)

gw_url = "http://" + ip + ":18789"
resp = api_call("POST", "/admin/agents", {
    "openclawBaseUrl": gw_url,
    "openclawGatewayUrl": gw_url,
    "openclawGatewayToken": token,
    "serverIp": ip,
    "serverRegion": REGION,
    "serverProvider": PROVIDER,
    "skipConnectivityCheck": True
}, auth_token)

agent_id = resp.get("data", {}).get("id", 0)
if agent_id:
    code = resp["data"].get("code", "?")
    print("[register] SUCCESS: agent #" + str(agent_id) + " (" + code + ")")
elif "already" in str(resp.get("error", "")).lower():
    print("[register] Already registered")
else:
    print("[register] FAILED: " + str(resp))
    sys.exit(1)
