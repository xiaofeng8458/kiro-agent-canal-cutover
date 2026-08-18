#!/usr/bin/env bash
# 跳板机执行：探明 instance 创建的正确端点/payload 形态（逐变体试，落库即停）
set -uo pipefail
. /root/canal_env.sh
cd /root/work
API=http://127.0.0.1:8089
DEST=server-0
export MYSQL_PWD="$DBADMIN_PWD"
mgr() { mysql -h "$PRIMARY" -u dbadmin -N -B --raw -e "$1"; }

echo "=== canal_instance_config 表结构 ==="
mysql -h "$PRIMARY" -u dbadmin -e "SHOW CREATE TABLE canal_manager.canal_instance_config\G" | sed -n '1,40p'

TK=$(curl -s -m 8 -X POST $API/api/v1/user/login -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWD}\"}" | jq -r '.data.token')
CONTENT=$(cat instance.properties.rehearsal)

try() {
  local label="$1" method="$2" body="$3"
  local n resp
  printf '\n--- [%s] %s ---\n' "$label" "$method"
  resp=$(curl -s -m 20 -X "$method" "$API/api/v1/canal/instance" -H "X-Token: $TK" \
    -H 'Content-Type: application/json' -d "$body")
  echo "resp: $(echo "$resp" | head -c 200)"
  n=$(mgr "SELECT COUNT(*) FROM canal_manager.canal_instance_config;")
  echo "落库行数: $n"
  [ "$n" != "0" ] && return 0 || return 1
}

B1=$(jq -n --arg c "$CONTENT" --arg n "$DEST" '{clusterId:1,name:$n,content:$c}')
B2=$(jq -n --arg c "$CONTENT" --arg n "$DEST" '{clusterServerId:"1:1",name:$n,content:$c}')
B3=$(jq -n --arg c "$CONTENT" --arg n "$DEST" '{clusterId:1,serverId:null,name:$n,content:$c,status:"1"}')
B4=$(jq -n --arg c "$CONTENT" --arg n "$DEST" '{clusterServerId:"c_1",name:$n,content:$c}')

try "B1 clusterId" POST "$B1" && { echo OK_B1; exit 0; }
try "B2 clusterServerId 1:1" POST "$B2" && { echo OK_B2; exit 0; }
try "B3 clusterId+status" POST "$B3" && { echo OK_B3; exit 0; }
try "B4 clusterServerId c_1" POST "$B4" && { echo OK_B4; exit 0; }

echo "全部变体未落库"
exit 1
