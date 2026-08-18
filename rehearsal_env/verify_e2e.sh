#!/usr/bin/env bash
# 跳板机执行：端到端链路验证 —— 建 topic -> 写 marker -> Kafka 消费 -> ZK cursor 推进
set -uo pipefail
. /root/canal_env.sh
. /root/msk_env.sh
export MYSQL_PWD="$DBADMIN_PWD"
CURSOR=/otter/canal/destinations/server-0/1001/cursor
KIMG=apache/kafka:3.7.0

zk() { kubectl -n common-service exec zookeeper-0 -- zkCli.sh -server localhost:2181 "$@" 2>/dev/null; }

echo "=== 1. 建 topic biz_test（MSK 关闭自动建 topic，必须手工建）==="
kubectl -n common-service delete pod kafka-admin --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n common-service run kafka-admin --restart=Never --image=$KIMG --command -- \
  sh -c "/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BROKERS --create --if-not-exists --topic biz_test --partitions 1 --replication-factor 2 && /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BROKERS --describe --topic biz_test" >/dev/null
for i in $(seq 1 40); do
  P=$(kubectl -n common-service get pod kafka-admin -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$P" = "Succeeded" ] || [ "$P" = "Failed" ] && break
  sleep 5
done
kubectl -n common-service logs kafka-admin 2>&1 | tail -5
kubectl -n common-service delete pod kafka-admin --wait=false >/dev/null 2>&1

echo "=== 2. cursor 写入前状态 ==="
zk get "$CURSOR" | grep -E '^\{' | tail -1 || echo "(cursor 尚未创建)"

echo "=== 3. 写 5 行 marker 到 primary ==="
TAG="e2e-$(date +%H%M%S)"
mysql -h "$PRIMARY" -u dbadmin -e \
  "INSERT INTO biz_test.marker(tag) VALUES ('$TAG-1'),('$TAG-2'),('$TAG-3'),('$TAG-4'),('$TAG-5');"
mysql -h "$PRIMARY" -u dbadmin -N -e \
  "SELECT CONCAT('primary marker 总行数=', COUNT(*)) FROM biz_test.marker;"
sleep 10
mysql -h "$READER" -u dbadmin -N -e \
  "SELECT CONCAT('reader  marker 总行数=', COUNT(*)) FROM biz_test.marker;"

echo "=== 4. Kafka 消费验证（预期 type=INSERT table=marker）==="
# ⚠️ canal 把同一事务的多行合并成 1 条 Kafka 消息（data[] 里 5 行），
# 所以 --max-messages 要按"消息条数"而不是"行数"给，否则等不满会以 TimeoutException 收尾（假故障）
kubectl -n common-service delete pod kafka-consumer --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n common-service run kafka-consumer --restart=Never --image=$KIMG --command -- \
  sh -c "/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BROKERS --topic biz_test --from-beginning --max-messages 1 --timeout-ms 60000" >/dev/null
for i in $(seq 1 40); do
  P=$(kubectl -n common-service get pod kafka-consumer -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$P" = "Succeeded" ] || [ "$P" = "Failed" ] && break
  sleep 5
done
echo "--- consumer pod phase=$P ---"
kubectl -n common-service logs kafka-consumer 2>&1 | head -20
echo "--- 消费到的 marker tag ---"
kubectl -n common-service logs kafka-consumer 2>&1 | grep -o '"tag":"[^"]*"' | sort -u
kubectl -n common-service delete pod kafka-consumer --wait=false >/dev/null 2>&1

echo "=== 5. cursor 写入后状态（gtid 应非空）==="
C=$(zk get "$CURSOR" | grep -E '^\{' | tail -1)
echo "$C"
echo "$C" | grep -oE '"gtid":"[^"]*"' || echo "!! cursor 无 gtid 字段"

echo "=== 6. instance 日志尾部（查异常）==="
kubectl -n common-service exec canal-server-0 -- \
  tail -15 /home/admin/canal-server/logs/server-0/server-0.log 2>&1 | tail -15
echo "DONE"
