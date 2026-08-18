#!/usr/bin/env bash
# 跳板机执行：从 canal-server 官方镜像取出 canal.properties / instance.properties 原始模板，
# 并取 MSK bootstrap。模板落 /root/work/。
set -uo pipefail
cd /root/work

# MSK ARN 由 ssm_run.sh 从本地透传（本地先 `source ./stack_outputs.sh`）
: "${MSK_CLUSTER_ARN:?缺少 MSK_CLUSTER_ARN（本地先 source ./stack_outputs.sh）}"
BROKERS=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "$MSK_CLUSTER_ARN" \
  --query BootstrapBrokerString --output text)
echo "BROKERS=$BROKERS"
echo "export BROKERS='$BROKERS'" > /root/msk_env.sh

kubectl -n common-service delete pod tmpl --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n common-service run tmpl --restart=Never --image=canal/canal-server:v1.1.8 \
  --command -- sleep 600 >/dev/null
kubectl -n common-service wait --for=condition=Ready pod/tmpl --timeout=180s || {
  kubectl -n common-service describe pod tmpl | tail -20; exit 1; }

echo "=== 镜像内 conf 目录 ==="
kubectl -n common-service exec tmpl -- ls /home/admin/canal-server/conf/
kubectl -n common-service exec tmpl -- cat /home/admin/canal-server/conf/canal.properties > canal.properties.template
kubectl -n common-service exec tmpl -- cat /home/admin/canal-server/conf/example/instance.properties > instance.properties.template
kubectl -n common-service delete pod tmpl --wait=false >/dev/null

wc -l canal.properties.template instance.properties.template
echo "=== canal.properties 关键行 ==="
grep -nE '^(canal\.zkServers|canal\.serverMode|canal\.destinations|canal\.instance\.global\.spring\.xml|kafka\.bootstrap\.servers)' canal.properties.template
echo "=== instance.properties 关键行 ==="
grep -nE '^(canal\.instance\.master\.address|canal\.instance\.dbUsername|canal\.instance\.dbPassword|canal\.instance\.gtidon|canal\.mq\.topic)' instance.properties.template
echo "DONE"
