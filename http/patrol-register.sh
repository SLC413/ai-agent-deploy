#!/usr/bin/env bash
# ============================================================
# patrol-register.sh — 智能体部署后验证 + 自动注册
#
# 工作原理：
#   1. 读取 /tmp/deploy-tracker.json 中的部署记录
#   2. 对每个"已部署 ≥30 分钟但未验证"的记录：
#      - 检查 VPS 上 OpenClaw 是否正常运行
#      - 正常运行 & 未注册 → 自动注册到管理平台
#      - 正常运行 & 已注册 → 标记为 done
#      - 未运行 → 记录失败原因，不上报注册
#
# 鉴权：ADMIN_API_KEY（Bearer），与 register-agent.py / quick-deploy 一致
#
# 配合 cron 每 10 分钟执行一次：
#   */10 * * * * ADMIN_API_KEY=xxx bash /home/ubuntu/ai-agent-deploy/http/patrol-register.sh
# ============================================================
set -euo pipefail

TRACKER_FILE="${TRACKER_FILE:-/tmp/deploy-tracker.json}"
: "${ADMIN_API:?need ADMIN_API (e.g. https://ai.xhl413.com/api)}"
ADMIN_API_KEY="${ADMIN_API_KEY:?ADMIN_API_KEY}"
CHECK_DELAY_MINUTES="${CHECK_DELAY_MINUTES:-30}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/agent01_tencent}"

if [ ! -f "$SSH_KEY" ]; then
  echo "❌ SSH_KEY 不存在: $SSH_KEY"
  exit 1
fi

echo "=========================================="
echo "  智能体注册巡逻 $(date '+%Y-%m-%d %H:%M')"
echo "=========================================="

# ── 1. 初始化跟踪文件 ──
if [ ! -f "$TRACKER_FILE" ]; then
  echo '[]' > "$TRACKER_FILE"
fi

# ── 2. 获取已注册智能体 IP 列表 ──
REGISTERED_IPS=$(curl -s "$ADMIN_API/admin/agents?limit=200" \
  -H "Authorization: Bearer $ADMIN_API_KEY" | \
  python3 -c "import sys,json; [print(a.get('serverIp','')) for a in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true)

# ── 3. 处理每个待验证的部署记录 ──
export TRACKER_FILE ADMIN_API ADMIN_API_KEY CHECK_DELAY_MINUTES SSH_KEY REGISTERED_IPS

UPDATED=$(python3 << 'PYEOF'
import json, time, subprocess, os

tracker_file = os.environ['TRACKER_FILE']
with open(tracker_file) as f:
    tracker = json.load(f)

registered_ips = set(os.environ.get('REGISTERED_IPS', '').splitlines())
check_delay = int(os.environ.get('CHECK_DELAY_MINUTES', '30'))
ssh_key = os.path.expanduser(os.environ.get('SSH_KEY', '~/.ssh/agent01_tencent'))
admin_api = os.environ['ADMIN_API'].rstrip('/')
admin_api_key = os.environ['ADMIN_API_KEY']
now = int(time.time())
updated = False
messages = []

for i, record in enumerate(tracker):
    status = record.get('status', 'deploying')
    if status in ('registered', 'failed', 'already_registered'):
        continue

    deploy_time = record.get('deploy_at', 0)
    elapsed = (now - deploy_time) // 60
    ip = record.get('ip', '')
    if elapsed < check_delay:
        continue

    gw_running = False
    gw_token = ''
    fail_reason = ''

    try:
        ssh_cmd = [
            'ssh', '-i', ssh_key,
            '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10',
            f'ubuntu@{ip}',
        ]
        r = subprocess.run(
            ssh_cmd + ['systemctl --user is-active openclaw-gateway 2>/dev/null || echo inactive'],
            capture_output=True, text=True, timeout=15,
        )
        if 'active' in r.stdout:
            gw_running = True
        elif 'inactive' in r.stdout:
            fail_reason = 'OpenClaw Gateway 未运行 (inactive)'
        else:
            fail_reason = f'OpenClaw Gateway 状态异常: {r.stdout.strip()}'

        if gw_running:
            r = subprocess.run(
                ssh_cmd + [
                    'python3 -c "import json; '
                    "print(json.load(open('/home/ubuntu/.openclaw/openclaw.json'))"
                    "['gateway']['auth']['token'])\""
                ],
                capture_output=True, text=True, timeout=10,
            )
            gw_token = r.stdout.strip()
            if not gw_token:
                gw_running = False
                fail_reason = '无法读取 Gateway Token'
    except Exception as e:
        fail_reason = f'SSH 连接失败: {e}'

    if not gw_running:
        tracker[i]['status'] = 'failed'
        tracker[i]['fail_reason'] = fail_reason
        tracker[i]['checked_at'] = now
        messages.append(f"[patrol] ❌ {ip} 部署失败: {fail_reason}")
        updated = True
        continue

    if ip in registered_ips:
        tracker[i]['status'] = 'already_registered'
        tracker[i]['checked_at'] = now
        messages.append(f"[patrol] ✅ {ip} 已注册（无需操作）")
        updated = True
        continue

    gw_url = f'http://{ip}:18789'
    region = record.get('region', 'Unknown')
    provider = record.get('provider', 'Tencent')
    reg_payload = json.dumps({
        'openclawBaseUrl': gw_url,
        'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': gw_token,
        'serverIp': ip,
        'serverRegion': region,
        'serverProvider': provider,
        'skipConnectivityCheck': True,
    })
    r = subprocess.run([
        'curl', '-s', '-X', 'POST', f'{admin_api}/admin/agents',
        '-H', 'Content-Type: application/json',
        '-H', f'Authorization: Bearer {admin_api_key}',
        '-d', reg_payload,
    ], capture_output=True, text=True, timeout=30)

    try:
        resp = json.loads(r.stdout)
        agent_id = resp.get('data', {}).get('id', 0)
        if agent_id:
            tracker[i]['status'] = 'registered'
            tracker[i]['agent_id'] = agent_id
            tracker[i]['checked_at'] = now
            messages.append(f"[patrol] ✅ {ip} 自动注册成功 → Agent #{agent_id}")
        elif 'already' in str(resp.get('error', '')).lower():
            tracker[i]['status'] = 'already_registered'
            tracker[i]['checked_at'] = now
            messages.append(f"[patrol] ⚠️  {ip} 已存在，跳过")
        else:
            tracker[i]['status'] = 'failed'
            tracker[i]['fail_reason'] = f'注册 API 返回错误: {r.stdout[:200]}'
            tracker[i]['checked_at'] = now
            messages.append(f"[patrol] ❌ {ip} 注册失败: {r.stdout[:200]}")
    except Exception:
        tracker[i]['status'] = 'failed'
        tracker[i]['fail_reason'] = '解析注册响应失败'
        tracker[i]['checked_at'] = now
        messages.append(f"[patrol] ❌ {ip} 注册失败: 无法解析响应")

    updated = True

if updated:
    with open(tracker_file, 'w') as f:
        json.dump(tracker, f, ensure_ascii=False, indent=2)

for msg in messages:
    print(msg, flush=True)
print(json.dumps(tracker, ensure_ascii=False))
PYEOF
)

echo "$UPDATED" | grep -v '^{' || true
echo "$UPDATED" | tail -1 | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
d = json.loads(raw)
for r in d:
    print(f\"  {r.get('ip',''):20s} {r.get('status',''):20s} {r.get('fail_reason','')}\")
" 2>/dev/null || true

echo ""
echo "=========================================="
echo "  巡逻完成"
echo "=========================================="
