#!/usr/bin/env bash
# 跳板机执行：部署 canal-server，确认自动注册进 rehearsal 集群
set -uo pipefail
. /root/canal_env.sh
cd /root/work
export MYSQL_PWD="$DBADMIN_PWD"
mgr() { mysql -h "$PRIMARY" -u dbadmin -N -B --raw -e "$1"; }

kubectl apply -f k8s/30-canal-server.yaml
kubectl -n common-service rollout status sts/canal-server --timeout=300s
kubectl -n common-service get pods -l app=canal-server -o wide

echo "=== 等待注册进 Admin（canal_node_server 表）==="
for i in $(seq 1 20); do
  N=$(mgr "SELECT COUNT(*) FROM canal_manager.canal_node_server;")
  [ "$N" != "0" ] && break
  sleep 6
done
mgr "SELECT id, cluster_id, name, ip, admin_port, tcp_port, status FROM canal_manager.canal_node_server;"

echo "=== canal-server 日志尾部（看是否连上 admin / 有无异常）==="
kubectl -n common-service logs canal-server-0 --tail=40 2>&1 | tail -40

echo "=== ZK 上的 canal 节点 ==="
kubectl -n common-service exec zookeeper-0 -- zkCli.sh -server localhost:2181 ls /otter/canal/destinations 2>/dev/null | tail -3
kubectl -n common-service exec zookeeper-0 -- zkCli.sh -server localhost:2181 ls /otter/canal/cluster 2>/dev/null | tail -3
echo "DONE"
