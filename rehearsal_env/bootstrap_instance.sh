#!/usr/bin/env bash
# 跳板机执行：创建 canal instance server-0（订阅只读副本，与生产一致）
set -uo pipefail
. /root/canal_env.sh
cd /root/work
API=http://127.0.0.1:8089
DEST=server-0
export MYSQL_PWD="$DBADMIN_PWD"
mgr() { mysql -h "$PRIMARY" -u dbadmin -N -B --raw -e "$1"; }

TK=$(curl -s -m 8 -X POST $API/api/v1/user/login -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWD}\"}" | jq -r '.data.token // empty')
[ -n "$TK" ] || { echo "Admin 登录失败"; exit 1; }

CID=$(curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/clusters" \
  | jq -r '.data[]? | select(.name=="rehearsal") | .id' | head -1)
echo "clusterId=$CID"

# ---- 生成 instance.properties（properties 不支持行内注释、不容忍尾随空格）----
READER_HOST="$READER" CANAL_PW="$CANAL_PWD" python3 - <<'PY'
import os, re
src = open('instance.properties.template').read().splitlines()
repl = {
    'canal.instance.master.address':  os.environ['READER_HOST'] + ':3306',
    'canal.instance.dbUsername':      'canal',
    'canal.instance.dbPassword':      os.environ['CANAL_PW'],
    'canal.instance.gtidon':          'true',
    'canal.mq.topic':                 'biz_test',
    'canal.instance.filter.regex':    'biz_test\\..*',
}
seen = set()
out = []
for line in src:
    m = re.match(r'^([A-Za-z0-9_.]+)\s*=', line)
    if m and m.group(1) in repl:
        k = m.group(1)
        out.append('%s=%s' % (k, repl[k]))
        seen.add(k)
    else:
        out.append(line)
for k, v in repl.items():
    if k not in seen:
        out.append('%s=%s' % (k, v))
open('instance.properties.rehearsal', 'w').write('\n'.join(out) + '\n')
print('生成 instance.properties.rehearsal，行数 =', len(out))
PY

echo "=== 关键行（密码打码）==="
grep -nE '^(canal\.instance\.master\.address|canal\.instance\.dbUsername|canal\.instance\.gtidon|canal\.mq\.topic|canal\.instance\.filter\.regex)=' instance.properties.rehearsal
grep -c '^canal\.instance\.dbPassword=' instance.properties.rehearsal | sed 's/^/dbPassword 行数: /'
echo "=== 尾随空格检查（应为 0）==="
grep -c '[[:space:]]$' instance.properties.rehearsal || true

# ---- 创建/更新 instance ----
# 实测要点：
#  - 新建走 POST，更新走 PUT（PUT 对不存在的行会静默返回 success 而不落库，别被骗）
#  - 归属主机必须用复合串 clusterServerId="1:<clusterId>"（前段 1=集群）；
#    只传 clusterId 会被拒："empty cluster or server id"
IID=$(curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/instances?page=1&size=50" \
  | jq -r --arg n "$DEST" '.data.items[]? | select(.name==$n) | .id' | head -1)
if [ -n "$IID" ]; then
  echo "instance $DEST 已存在 id=$IID，走 PUT 更新"
  METHOD=PUT
  jq -n --arg c "$(cat instance.properties.rehearsal)" --arg n "$DEST" \
    --argjson cid "$CID" --argjson id "$IID" \
    '{id:$id, clusterServerId:("1:"+($cid|tostring)), name:$n, content:$c, status:"1"}' > inst.json
else
  echo "新建 instance $DEST，走 POST"
  METHOD=POST
  jq -n --arg c "$(cat instance.properties.rehearsal)" --arg n "$DEST" --argjson cid "$CID" \
    '{clusterServerId:("1:"+($cid|tostring)), name:$n, content:$c}' > inst.json
fi

echo "--- $METHOD /api/v1/canal/instance ---"
curl -s -m 20 -X "$METHOD" "$API/api/v1/canal/instance" -H "X-Token: $TK" \
  -H 'Content-Type: application/json' -d @inst.json | head -c 300
echo

echo "=== canal_instance_config 表 ==="
mgr "SELECT id, cluster_id, server_id, name, LENGTH(content) AS len, status FROM canal_manager.canal_instance_config;"
echo "=== API 侧 instances ==="
curl -s -m 8 -H "X-Token: $TK" "$API/api/v1/canal/instances?page=1&size=50" | jq -c '.data.items'
echo "DONE"
