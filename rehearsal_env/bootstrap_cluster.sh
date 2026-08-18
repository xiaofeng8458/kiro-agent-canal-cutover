#!/usr/bin/env bash
# 跳板机执行：改 Admin 默认口令 -> 建 rehearsal 集群 -> 下发主配置（canal.properties）
set -uo pipefail
. /root/canal_env.sh
. /root/msk_env.sh
cd /root/work
API=http://127.0.0.1:8089
export MYSQL_PWD="$DBADMIN_PWD"

mgr() { mysql -h "$PRIMARY" -u dbadmin -N -B --raw -e "$1"; }

# ---------- 1. 改 Admin UI 口令（默认 123456 是公开默认值） ----------
if grep -q '^export ADMIN_PASSWD=' /root/canal_env.sh 2>/dev/null; then
  echo "ADMIN_PASSWD 已存在，跳过改密"
else
  # canal-admin 口令哈希 = UPPER(SHA1(UNHEX(SHA1(pwd))))，即 MySQL PASSWORD() 的双层 SHA1（已实测确认）
  OLD_HASH=$(mgr "SELECT password FROM canal_manager.canal_user WHERE username='admin';")
  SHA_OF_123456=$(mgr "SELECT UPPER(SHA1(UNHEX(SHA1('123456'))));")
  echo "当前哈希前 8 位=${OLD_HASH:0:8}  双层SHA1('123456') 前 8 位=${SHA_OF_123456:0:8}"
  if [ "$OLD_HASH" != "$SHA_OF_123456" ]; then
    echo "口令哈希方案不符预期，放弃自动改密（保持默认，改由 UI 手工改）"
  else
    NEW_PWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    mgr "UPDATE canal_manager.canal_user SET password=UPPER(SHA1(UNHEX(SHA1('${NEW_PWD}')))) WHERE username='admin';"
    CODE=$(curl -s -m 8 -X POST $API/api/v1/user/login -H 'Content-Type: application/json' \
      -d "{\"username\":\"admin\",\"password\":\"${NEW_PWD}\"}" | jq -r '.code // empty')
    if [ "$CODE" = "20000" ]; then
      umask 077
      echo "export ADMIN_PASSWD='${NEW_PWD}'" >> /root/canal_env.sh
      echo "Admin 口令已改，新口令写入 /root/canal_env.sh"
    else
      mgr "UPDATE canal_manager.canal_user SET password='${OLD_HASH}' WHERE username='admin';"
      echo "新口令登录失败，已回滚为原哈希（仍是默认 123456）"
    fi
  fi
  . /root/canal_env.sh
fi

ADMIN_PASSWD=${ADMIN_PASSWD:-123456}
TK=$(curl -s -m 8 -X POST $API/api/v1/user/login -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWD}\"}" | jq -r '.data.token // empty')
[ -n "$TK" ] || { echo "Admin 登录失败，中止"; exit 1; }
echo "登录成功"

# ---------- 2. 建 rehearsal 集群（幂等） ----------
CID=$(curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/clusters" \
  | jq -r '.data[]? | select(.name=="rehearsal") | .id' | head -1)
if [ -z "$CID" ]; then
  echo "--- 创建集群 rehearsal ---"
  curl -s -m 8 -X POST "$API/api/v1/canal/cluster" -H "X-Token: $TK" \
    -H 'Content-Type: application/json' \
    -d '{"name":"rehearsal","zkHosts":"zookeeper.common-service:2181"}' | head -c 300
  echo
  CID=$(curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/clusters" \
    | jq -r '.data[]? | select(.name=="rehearsal") | .id' | head -1)
fi
[ -n "$CID" ] || { echo "集群创建失败，中止"; exit 1; }
echo "clusterId=$CID"

# ---------- 3. 主配置：模板全量 + 5 处修改 ----------
# 踩坑留档：只存 4 行会让 canal-server NPE 崩溃，必须整份模板；
# canal.destinations 必须清空（Admin 托管模式下静态 destinations 找不到配置）
cp canal.properties.template canal.properties.rehearsal
sed -i \
  -e "s|^canal.zkServers *=.*|canal.zkServers = zookeeper.common-service:2181|" \
  -e "s|^canal.serverMode *=.*|canal.serverMode = kafka|" \
  -e "s|^canal.destinations *=.*|canal.destinations =|" \
  -e "s|^canal.instance.global.spring.xml *=.*|canal.instance.global.spring.xml = classpath:spring/default-instance.xml|" \
  -e "s|^kafka.bootstrap.servers *=.*|kafka.bootstrap.servers = ${BROKERS}|" \
  canal.properties.rehearsal

echo "=== 改后关键行 ==="
grep -nE '^(canal\.zkServers|canal\.serverMode|canal\.destinations|canal\.instance\.global\.spring\.xml|kafka\.bootstrap\.servers)' canal.properties.rehearsal

# canal-admin 1.1.8 的主配置保存只有 PUT 映射（POST 返回 405，已实测），新建/更新同一入口
EXIST=$(curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/config/${CID}/0" | jq -r '.data.id // empty')
jq -n --arg c "$(cat canal.properties.rehearsal)" --argjson cid "$CID" \
  '{clusterId:$cid, serverId:null, name:"canal.properties", content:$c}' > payload.json
if [ -n "$EXIST" ]; then
  echo "--- 主配置已存在(id=$EXIST)，带 id 更新 ---"
  jq --argjson id "$EXIST" '. + {id:$id}' payload.json > payload_up.json
  mv payload_up.json payload.json
else
  echo "--- 新建主配置 ---"
fi
curl -s -m 20 -X PUT "$API/api/v1/canal/config" -H "X-Token: $TK" \
  -H 'Content-Type: application/json' -d @payload.json | head -c 300
echo

# ---------- 4. 回读校验 ----------
echo "=== 回读主配置（DB 侧）==="
mgr "SELECT id, cluster_id, server_id, name, LENGTH(content) AS content_len FROM canal_manager.canal_config;"
echo "=== 回读关键行（从 API）==="
curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/config/${CID}/0" \
  | jq -r '.data.content // "NULL"' \
  | grep -E '^(canal\.zkServers|canal\.serverMode|canal\.destinations|canal\.instance\.global\.spring\.xml|kafka\.bootstrap\.servers)'
echo "DONE"
