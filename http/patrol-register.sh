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
# 配合 cron 每 10 分钟执行一次：
#   */10 * * * * bash /home/ubuntu/ai-agent-deploy/patrol-register.sh
# ============================================================
set -euo pipefail

TRACKER_FILE="/tmp/deploy-tracker.json"
ADMIN_API="${ADMIN_API:-https://www.nika8.com/api}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:*** ADMIN_PASSWORD}"
CHECK_DELAY_MINUTES="${CHECK_DELAY_MINUTES:-30}"  # 部署后等多少分钟再检查

echo "=========================================="
echo "  🛡️  智能体注册巡逻 $(date '+%Y-%m-%d %H:%M')"
echo "=========================================="

# ── 1. 初始化/读取跟踪文件 ──
if [ ! -f "$TRACKER_FILE" ]; then
  echo '[]' > "$TRACKER_FILE"
fi

TRACKER=$(cat "$TRACKER_FILE")

# ── 2. 登录管理平台 ──
LOGIN_RESP=$(curl -s -X POST "$ADMIN_API/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")

ADMIN_TOKEN=*** "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('token',''))"

if [ -z "$ADMIN_TOKEN" ]; then
  echo "❌ 登录管理平台失败"
  exit 1
fi

# ── 3. 获取已注册智能体 IP 列表 ──
REGISTERED_IPS=$(curl -s "$ADMIN_API/api/admin/agents?limit=200" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | \
  python3 -c "import sys,json; [print(a.get('serverIp','')) for a in json.load(sys.stdin).get('data',[])]" 2>/dev/null)

# ── 4. 处理每个待验证的部署记录 ──
UPDATED=$(python3 << PYEOF
import json, sys, time, subprocess, os

tracker = json.loads(sys.stdin.read())
registered_ips = set(os.environ.get('REGISTERED_IPS','').splitlines())
check_delay = int(os.environ.get('CHECK_DELAY_MINUTES', '30'))
now = int(time.time())
updated = False

for i, record in enumerate(tracker):
    status = record.get('status', 'deploying')
    
    # 跳过已处理的
    if status in ('registered', 'failed', 'already_registered'):
        continue
    
    deploy_time = record.get('deploy_at', 0)
    elapsed = (now - deploy_time) // 60
    ip = record.get('ip', '')
    
    # 还没到检查时间
    if elapsed < check_delay:
        continue
    
    # 检查 VPS 状态
    gw_running = False
    gw_token = ''
    fail_reason = ''
    
    try:
        # SSH 连通性
        ssh_cmd = ['ssh', '-i', os.path.expanduser('~/.ssh/agent01_tencent'),
                   '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10',
                   f'ubuntu@{ip}']
        
        # 检查 OpenClaw 是否运行
        r = subprocess.run(ssh_cmd + ['systemctl --user is-active openclaw-gateway 2>/dev/null || echo inactive'],
                          capture_output=True, text=True, timeout=15)
        if 'active' in r.stdout:
            gw_running = True
        elif 'inactive' in r.stdout:
            fail_reason = 'OpenClaw Gateway 未运行 (inactive)'
        else:
            fail_reason = f'OpenClaw Gateway 状态异常: {r.stdout.strip()}'
        
        # 读取 Gateway Token
        if gw_running:
            r = subprocess.run(ssh_cmd + ['python3 -c "import json; print(json.load(open(\\\"\$HOME/.openclaw/openclaw.json\\\"))[\\\"gateway\\\"][\\\"auth\\\"][\\\"token\\\"])"'],
                              capture_output=True, text=True, timeout=10)
            gw_token = r.stdout.strip()
            if not gw_token:
                gw_running = False
                fail_reason = '无法读取 Gateway Token'
    except Exception as e:
        fail_reason = f'SSH 连接失败: {e}'
    
    # 决定处理方式
    if not gw_running:
        tracker[i]['status'] = 'failed'
        tracker[i]['fail_reason'] = fail_reason
        tracker[i]['checked_at'] = now
        print(f"[patrol] ❌ {ip} 部署失败: {fail_reason}")
        updated = True
        continue
    
    # Gateway 正常运行，检查是否已注册
    if ip in registered_ips:
        tracker[i]['status'] = 'already_registered'
        tracker[i]['checked_at'] = now
        print(f"[patrol] ✅ {ip} 已注册（无需操作）")
        updated = True
        continue
    
    # 需要注册
    gw_url = f'http://{ip}:18789'
    region = record.get('region', 'Unknown')
    provider = record.get('provider', 'Tencent')
    
    # 调用管理平台 API 注册
    reg_payload = json.dumps({
        'openclawBaseUrl': gw_url,
        'openclawGatewayUrl': gw_url,
        'openclawGatewayToken': gw_token,
        'serverIp': ip,
        'serverRegion': region,
        'serverProvider': provider,
        'skipConnectivityCheck': True
    })
    
    curl_cmd = ['curl', '-s', '-X', 'POST',
                f'{os.environ["ADMIN_API"]}/api/admin/agents',
                '-H', 'Content-Type: application/json',
                '-H', f'Authorization: Bearer {os.environ["ADMIN_TOKEN"]}',
                '-d', reg_payload]
    
    r = subprocess.run(curl_cmd, capture_output=True, text=True, timeout=30)
    
    try:
        resp = json.loads(r.stdout)
        agent_id = resp.get('data', {}).get('id', 0)
        if agent_id:
            tracker[i]['status'] = 'registered'
            tracker[i]['agent_id'] = agent_id
            tracker[i]['checked_at'] = now
            print(f"[patrol] ✅ {ip} 自动注册成功 → Agent #{agent_id}")
        elif 'already' in str(resp.get('error', '')).lower():
            tracker[i]['status'] = 'already_registered'
            tracker[i]['checked_at'] = now
            print(f"[patrol] ⚠️  {ip} 已存在，跳过")
        else:
            tracker[i]['status'] = 'failed'
            tracker[i]['fail_reason'] = f'注册 API 返回错误: {r.stdout[:200]}'
            tracker[i]['checked_at'] = now
            print(f"[patrol] ❌ {ip} 注册失败: {r.stdout[:200]}")
    except Exception:
        tracker[i]['status'] = 'failed'
        tracker[i]['fail_reason'] = f'解析注册响应失败'
        tracker[i]['checked_at'] = now
        print(f"[patrol] ❌ {ip} 注册失败: 无法解析响应")
    
    updated = True

if updated:
    with open(os.environ.get('TRACKER_FILE', '/tmp/deploy-tracker.json'), 'w') as f:
        json.dump(tracker, f, ensure_ascii=False, indent=2)

print(json.dumps(tracker, ensure_ascii=False))
PYEOF
)
echo "$UPDATED" | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); [print(f'  {r[\"ip\"]:20s} {r[\"status\"]:20s} {r.get(\"fail_reason\",\"\")}') for r in d]" 2>/dev/null

echo ""
echo "=========================================="
echo "  巡逻完成"
echo "=========================================="
