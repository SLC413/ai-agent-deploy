#!/usr/bin/env bash
# ============================================================
# register-agent.sh — 手动注册智能体到管理平台
# 用法: ./register-agent.sh <服务器IP> <管理员邮箱> <管理员密码> [地区] [云商]
# ============================================================
set -euo pipefail

IP="${1:?用法: ./register-agent.sh <IP> <EMAIL> <PASSWORD> [REGION] [PROVIDER]}"
EMAIL="${2:?缺少管理员邮箱}"
PASSWORD="${3:?缺少管理员密码}"
REGION="${4:-Singapore}"
PROVIDER="${5:-Tencent}"
ADMIN_API="${ADMIN_API:-https://www.nika8.com/api}"
CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"

if [ ! -f "$CONFIG" ]; then
  echo "❌ 找不到 OpenClaw 配置: $CONFIG"
  exit 1
fi

# 读取 Gateway Token
TOKEN=$(python3 -c "import json; print(json.load(open('$CONFIG'))['gateway']['auth']['token'])")
echo "[register] Gateway Token: ${TOKEN:0:8}...${TOKEN: -4}"

# 登录管理平台
echo "[register] 登录 $ADMIN_API ..."
LOGIN_RESP=$(curl -s -X POST "$ADMIN_API/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null)

ADMIN_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('token',''))" 2>/dev/null)

if [ -z "$ADMIN_TOKEN" ]; then
  echo "❌ 登录失败: $LOGIN_RESP"
  exit 1
fi
echo "[register] 登录成功"

# 注册智能体
GW_URL="http://${IP}:18789"
echo "[register] 注册智能体: $GW_URL ..."

REG_RESP=$(curl -s -X POST "$ADMIN_API/api/admin/agents" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d "{
    \"openclawBaseUrl\": \"$GW_URL\",
    \"openclawGatewayUrl\": \"$GW_URL\",
    \"openclawGatewayToken\": \"$TOKEN\",
    \"serverIp\": \"$IP\",
    \"serverRegion\": \"$REGION\",
    \"serverProvider\": \"$PROVIDER\",
    \"skipConnectivityCheck\": true
  }" 2>/dev/null)

AGENT_ID=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)

if [ -n "$AGENT_ID" ]; then
  AGENT_CODE=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('code',''))" 2>/dev/null)
  echo "✅ 注册成功: Agent #$AGENT_ID ($AGENT_CODE)"
else
  ERROR_MSG=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','未知错误'))" 2>/dev/null)
  if echo "$ERROR_MSG" | grep -qi 'already'; then
    echo "⚠️  智能体已注册: $ERROR_MSG"
  else
    echo "❌ 注册失败: $REG_RESP"
    exit 1
  fi
fi
