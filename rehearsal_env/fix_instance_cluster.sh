#!/usr/bin/env bash
# 跳板机执行：把 instance 配置行的归属补成 cluster_id=1，并以 ZK 为最终判据验证 canal-server 接管。
#
# 背景：canal-admin 1.1.8 建 instance 必须 POST（PUT 对不存在行静默 success），
# 归属字段走 clusterServerId 复合串——但 "1:1" 落库后 cluster_id 仍为 NULL，
# 前端 chunk 里的真实拼法追查成本过高。canal-server 是按"本集群配置行存在性"轮询的，
# 因此直接补 cluster_id 是等效且可验证的做法（判据不看 API，只看 ZK）。
set -uo pipefail
. /root/canal_env.sh
export MYSQL_PWD="$DBADMIN_PWD"
mgr() { mysql -h "$PRIMARY" -u dbadmin -N -B --raw -e "$1"; }

echo "=== 修改前 ==="
mgr "SELECT id, cluster_id, server_id, name, status, content_md5 FROM canal_manager.canal_instance_config;"

mgr "UPDATE canal_manager.canal_instance_config
     SET cluster_id = 1,
         server_id  = NULL,
         status     = '1',
         content_md5 = MD5(content)
     WHERE name = 'server-0';"

echo "=== 修改后 ==="
mgr "SELECT id, cluster_id, server_id, name, status, content_md5 FROM canal_manager.canal_instance_config;"

echo "=== 等 canal-server 轮询接管（判据：ZK 出现 destination 与 running 节点）==="
for i in $(seq 1 30); do
  D=$(kubectl -n common-service exec zookeeper-0 -- zkCli.sh -server localhost:2181 \
        ls /otter/canal/destinations 2>/dev/null | grep -E '^\[' | tail -1)
  echo "[$i] destinations=$D"
  echo "$D" | grep -q 'server-0' && break
  sleep 6
done

echo "=== ZK 细节 ==="
for p in /otter/canal/destinations/server-0 /otter/canal/destinations/server-0/1001; do
  printf '%s -> ' "$p"
  kubectl -n common-service exec zookeeper-0 -- zkCli.sh -server localhost:2181 ls "$p" 2>/dev/null | grep -E '^\[' | tail -1
done
printf 'running 节点 -> '
kubectl -n common-service exec zookeeper-0 -- zkCli.sh -server localhost:2181 \
  stat /otter/canal/destinations/server-0/running 2>/dev/null | grep -c cZxid

echo "=== instance 日志 ==="
kubectl -n common-service exec canal-server-0 -- sh -c \
  'ls /home/admin/canal-server/logs/; tail -40 /home/admin/canal-server/logs/server-0/server-0.log' 2>&1 | tail -45
echo "DONE"
