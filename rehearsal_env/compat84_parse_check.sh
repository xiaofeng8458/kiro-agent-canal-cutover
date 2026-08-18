#!/usr/bin/env bash
# 跳板机执行：8.4 兼容性预检 第 3 项（报文解析）。
# 用一次性隔离 pod 起 canal-server：local/file 模式（file-instance.xml，不写 ZK）、
# tcp 模式（不碰 Kafka）、指向 8.4 临时实例。完全不干扰正在跑的 server-0 与演练基线。
# 用法: compat84_parse_check.sh [认证插件 native|sha2，默认 native]
set -uo pipefail
. /home/ec2-user/.canal/secrets.sh
WHICH="${1:-native}"
TSDB="${2:-false}"          # tsdb 开关：原环境模板默认 true，会多发 SHOW CREATE TABLE 等查询
case "$WHICH" in
  native) DBUSER=canal ;;
  sha2)   DBUSER=canal_sha2 ;;
  *) echo "用法: $0 [native|sha2] [tsdb true|false]"; exit 1 ;;
esac
POD="canal84-$WHICH-tsdb$TSDB"
NS=common-service
cd /root/work

echo "被测: $DBUSER@$H84 （插件组: $WHICH）"

# ---- canal.properties：本地文件位点 + tcp，彻底隔离 ----
cp canal.properties.template canal84.properties
sed -i \
  -e "s|^canal.zkServers *=.*|canal.zkServers =|" \
  -e "s|^canal.serverMode *=.*|canal.serverMode = tcp|" \
  -e "s|^canal.destinations *=.*|canal.destinations = example|" \
  -e "s|^canal.instance.global.spring.xml *=.*|canal.instance.global.spring.xml = classpath:spring/file-instance.xml|" \
  -e "s|^canal.auto.reset.latest.pos.mode *=.*|canal.auto.reset.latest.pos.mode = false|" \
  canal84.properties

# ---- instance.properties：指向 8.4，GTID 模式，tsdb 关（避免 timestamp 硬校验混入本次结论）----
DBUSER="$DBUSER" PW="$CANAL84_PWD" H="$H84" TSDB="$TSDB" python3 - <<'PY'
import os, re
repl = {
  'canal.instance.master.address': os.environ['H'] + ':3306',
  'canal.instance.dbUsername':     os.environ['DBUSER'],
  'canal.instance.dbPassword':     os.environ['PW'],
  'canal.instance.gtidon':         'true',
  'canal.instance.tsdb.enable':    os.environ['TSDB'],
  'canal.instance.filter.regex':   'compat_test\\..*',
  'canal.mq.topic':                'compat_test',
}
src = open('instance.properties.template').read().splitlines()
seen, out = set(), []
for line in src:
    m = re.match(r'^([A-Za-z0-9_.]+)\s*=', line)
    if m and m.group(1) in repl:
        out.append('%s=%s' % (m.group(1), repl[m.group(1)])); seen.add(m.group(1))
    else:
        out.append(line)
for k, v in repl.items():
    if k not in seen: out.append('%s=%s' % (k, v))
open('instance84.properties','w').write('\n'.join(out) + '\n')
print('instance84.properties 行数 =', len(out))
PY

kubectl -n $NS delete configmap canal84-conf --ignore-not-found >/dev/null
kubectl -n $NS create configmap canal84-conf \
  --from-file=canal.properties=canal84.properties \
  --from-file=instance.properties=instance84.properties >/dev/null

kubectl -n $NS delete pod $POD --ignore-not-found --wait=true >/dev/null 2>&1
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: canal-server
      image: canal/canal-server:v1.1.8
      resources:
        requests: {memory: 512Mi, cpu: 200m}
        limits:   {memory: 1200Mi}
      volumeMounts:
        - {name: conf, mountPath: /home/admin/canal-server/conf/canal.properties, subPath: canal.properties}
        - {name: conf, mountPath: /home/admin/canal-server/conf/example/instance.properties, subPath: instance.properties}
  volumes:
    - name: conf
      configMap: {name: canal84-conf}
EOF

echo "--- 等 pod Running ---"
kubectl -n $NS wait --for=condition=Ready pod/$POD --timeout=180s || {
  kubectl -n $NS describe pod $POD | tail -20; exit 1; }

echo "--- 等 canal 起 instance 并寻位（60s）---"
sleep 60

echo
echo "############ 判据取证 ############"
echo "=== stdout ==="
kubectl -n $NS logs $POD 2>&1 | tail -12
echo
echo "=== instance 日志（example.log）==="
kubectl -n $NS exec $POD -- sh -c 'cat /home/admin/canal-server/logs/example/example.log 2>/dev/null | tail -60' 2>&1 | tail -60
echo
echo "=== 关键判据抓取 ==="
LOG=$(kubectl -n $NS exec $POD -- sh -c 'cat /home/admin/canal-server/logs/example/example.log 2>/dev/null' 2>/dev/null)
printf '%-46s ' "认证/连接成功（load MySQL @@version_comment）"; echo "$LOG" | grep -c "version_comment" || true
printf '%-46s ' "寻位成功（find start position successfully）"; echo "$LOG" | grep -c "find start position successfully" || true
printf '%-46s ' "报文解析异常（ArrayIndexOutOfBounds）"; echo "$LOG" | grep -c "ArrayIndexOutOfBounds" || true
printf '%-46s ' "语法错误（1064 / You have an error）"; echo "$LOG" | grep -ciE "1064|You have an error in your SQL" || true
printf '%-46s ' "SHOW MASTER STATUS 相关报错"; echo "$LOG" | grep -ciE "show master status" || true
printf '%-46s ' "认证插件报错（Authentication|plugin）"; echo "$LOG" | grep -ciE "authentication .*fail|unknown plugin|plugin .*not loaded" || true
printf '%-46s ' "1236"; echo "$LOG" | grep -c "1236" || true
echo
echo "=== 全部异常行 ==="
echo "$LOG" | grep -iE "exception|error|caused by" | head -25
echo "DONE_POD=$POD"
