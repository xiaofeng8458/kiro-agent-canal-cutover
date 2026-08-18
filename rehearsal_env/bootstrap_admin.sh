#!/usr/bin/env bash
# 跳板机执行：导入 canal_manager 表结构 + 建 k8s secret + 部署 canal-admin
set -uo pipefail
. /root/canal_env.sh
cd /root/work

# 1. 官方 canal_manager.sql 建表（幂等：已有 canal_user 表则跳过）
export MYSQL_PWD="$DBADMIN_PWD"
HAS=$(mysql -h "$PRIMARY" -u dbadmin -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='canal_manager' AND table_name='canal_user';")
if [ "$HAS" = "0" ]; then
  [ -f canal_manager.sql ] || curl -fsSL -o canal_manager.sql \
    https://raw.githubusercontent.com/alibaba/canal/canal-1.1.8/admin/admin-web/src/main/resources/canal_manager.sql
  # 官方脚本含 CREATE DATABASE/USE canal_manager，直接整体执行
  mysql -h "$PRIMARY" -u dbadmin < canal_manager.sql || { echo "canal_manager.sql 导入失败"; exit 1; }
  echo "canal_manager 表结构已导入"
else
  echo "canal_manager 表结构已存在，跳过导入"
fi
mysql -h "$PRIMARY" -u dbadmin -N -e \
  "SELECT CONCAT('canal_manager 表数: ', COUNT(*)) FROM information_schema.tables WHERE table_schema='canal_manager';"

# 2. canal-admin 的 DB 凭证 secret（幂等重建）
kubectl -n common-service delete secret canal-admin-db --ignore-not-found >/dev/null
kubectl -n common-service create secret generic canal-admin-db \
  --from-literal=address="${PRIMARY}:3306" \
  --from-literal=username='canal_admin' \
  --from-literal=password="${CANAL_ADMIN_PWD}" >/dev/null
echo "secret canal-admin-db 已创建"

# 3. 部署 canal-admin
kubectl apply -f k8s/20-canal-admin.yaml
kubectl -n common-service rollout status deploy/canal-admin --timeout=240s
kubectl -n common-service get pods -l app=canal-admin

# 4. ZK 四字命令自检（runbook 对账依赖 srvr/cons）
echo "=== ZK ruok/srvr ==="
kubectl -n common-service exec zookeeper-0 -- sh -c 'echo ruok | nc localhost 2181' 2>/dev/null; echo
kubectl -n common-service exec zookeeper-0 -- sh -c 'echo srvr | nc localhost 2181' 2>/dev/null | head -5
echo "DONE"
