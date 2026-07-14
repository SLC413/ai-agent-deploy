#!/usr/bin/env bash
# ============================================================
# patrol-register.sh — 智能体注册巡逻脚本
# 用法: ./patrol-register.sh
#
# 1. 查询管理平台已注册的智能体列表
# 2. 对比各 VPS 上运行的 OpenClaw Gateway
# 3. 发现未注册的自动调用 register-agent.sh 注册
# ============================================================
set -euo pipefail

ADMIN_API="${ADMIN_API:-https://www.nika8.com/api}"
ADMIN_EMAIL="${ADMIN_EMAIL:?请设置 ADMIN_EMAIL}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?请设置 ADMIN_PASSWORD}"
AGENT_REGION="${AGENT_REGION:-Unknown}"
AGENT_PROVIDER="${AGENT_PROVIDER:-Tencent}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  🛡️  智能体注册巡逻 $(date '+%Y-%m-%d %H:%M')"
echo "=========================================="

# ── 1. 登录管理平台 ──
LOGIN_RESP=$(curl -s -X POST "$ADMIN_API/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")

ADMIN_TOKEN=*** "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('token',''))")

if [ -z "$ADMIN_TOKEN" ]; then
  echo "❌ 登录失败"
  exit 1
fi

# ── 2. 获取已注册智能体列表 ──
REGISTERED_IPS=$(curl -s "$ADMIN_API/admin/agents?limit=200" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | \
  python3 -c "
import sys,json
data = json.load(sys.stdin).get('data',[])
for agent in data:
    print(agent.get('serverIp',''))
" 2>/dev/null)

echo "[patrol] 已注册 ${REGISTERED_IPS:*** -c} 台智能体"

# ── 3. 扫描目标 VPS 列表 ──
# 从环境变量读取 VPS 列表（逗号分隔），或仅检查已注册的
TARGET_IPS="${TARGET_IPS:-$REGISTERED_IPS}"

NEW_COUNT=0
FIXED_COUNT=0

for IP in $TARGET_IPS; do
  [ -z "$IP" ] && continue
  
  # 检查是否已注册
  if echo "$REGISTERED_IPS" | grep -qF "$IP"; then
    continue  # 已注册，跳过
  fi
  
  echo ""
  echo "🔍 发现未注册智能体: $IP"
  
  # 检查 SSH 连通性
  if ! ssh -i ~/.ssh/agent01_tencent -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$IP" 'hostname' &>/dev/null; then
    echo "   ⚠️  SSH 不通，跳过"
    continue
  fi
  
  # 检查 OpenClaw 是否运行
  if ! ssh -i ~/.ssh/agent01_tencent -o StrictHostKeyChecking=no ubuntu@"$IP" \
    'systemctl --user is-active openclaw-gateway 2>/dev/null || true' | grep -q active; then
    echo "   ⚠️  OpenClaw Gateway 未运行，跳过"
    continue
  fi
  
  # 读取 Gateway Token
  GW_TOKEN=$(ssh -i ~/.ssh/agent01_tencent -o StrictHostKeyChecking=no ubuntu@"$IP" \
    'python3 -c "import json; print(json.load(open(\"$HOME/.openclaw/openclaw.json\"))[\"gateway\"][\"auth\"][\"token\"])"' 2>/dev/null)
  
  if [ -z "$GW_TOKEN" ]; then
    echo "   ⚠️  无法读取 Gateway Token，跳过"
    continue
  fi
  
  # 注册
  echo "   📝 注册中..."
  GW_URL="http://${IP}:18789"
  REG_RESP=$(curl -s -X POST "$ADMIN_API/admin/agents" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{
      \"openclawBaseUrl\": \"$GW_URL\",
      \"openclawGatewayUrl\": \"$GW_URL\",
      \"openclawGatewayToken\": \"$GW_TOKEN\",
      \"serverIp\": \"$IP\",
      \"serverRegion\": \"$AGENT_REGION\",
      \"serverProvider\": \"$AGENT_PROVIDER\",
      \"skipConnectivityCheck\": true
    }")
  
  AGENT_ID=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',0))" 2>/dev/null)
  
  if [ "${AGENT_ID:-0}" -gt 0 ]; then
    echo "   ✅ 注册成功: Agent #$AGENT_ID"
    ((NEW_COUNT++)) || true
  else
    echo "   ❌ 注册失败: $REG_RESP"
  fi
done

echo ""
echo "=========================================="
echo "  巡逻完成: 新增 $NEW_COUNT 台智能体"
echo "=========================================="
