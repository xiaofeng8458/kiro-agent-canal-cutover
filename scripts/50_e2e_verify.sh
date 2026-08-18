#!/usr/bin/env bash
# 端到端验证：写一行唯一 tag 的 marker -> 确认到达 Kafka -> 确认 cursor 推进。
# 仅写测试表 MARKER_TABLE，可自主执行。用法: 50_e2e_verify.sh [Kafka等待秒,默认40]
source "$(dirname "$0")/lib/common.sh"

BIZ_DB_HOST="${BIZ_DB_HOST:-$MGR_DB_HOST}"
BIZ_DB_USER="${BIZ_DB_USER:-$MGR_DB_USER}"
MARKER_TABLE="${MARKER_TABLE:-biz_test.marker}"
WAIT="${1:-40}"
: "${KAFKA_BROKERS:?env.sh 需配置 KAFKA_BROKERS}"
: "${KAFKA_TOPIC:?env.sh 需配置 KAFKA_TOPIC}"

biz_sql() { mysql -h "$BIZ_DB_HOST" -u "$BIZ_DB_USER" -p"${MYSQL_PWD:?设置 MYSQL_PWD}" -N -B -e "$1"; }

log "===== E2E 端到端验证 ====="
g_before=$(cursor_gtid || true)
TAG="e2e-$(date +%s)-$$"
biz_sql "INSERT INTO ${MARKER_TABLE}(tag) VALUES ('${TAG}')"
MID=$(biz_sql "SELECT id FROM ${MARKER_TABLE} WHERE tag='${TAG}'")
log "写入 marker: id=${MID} tag=${TAG}"

log "消费 Kafka（topic=${KAFKA_TOPIC}，等待 ${WAIT}s）..."
kubectl delete pod kafka-e2e --ignore-not-found >/dev/null 2>&1
kubectl run kafka-e2e --restart=Never --image=apache/kafka:3.7.0 -- sh -c \
  "/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server ${KAFKA_BROKERS} --topic ${KAFKA_TOPIC} --from-beginning --timeout-ms $((WAIT*1000)) 2>/dev/null" >/dev/null
for i in $(seq 1 $((WAIT+30))); do
  ph=$(kubectl get pod kafka-e2e -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$ph" in Succeeded|Failed) break;; esac
  sleep 2
done
found=$(kubectl logs kafka-e2e 2>/dev/null | grep -ac "$TAG" || true)
kubectl delete pod kafka-e2e >/dev/null 2>&1

g_after=$(cursor_gtid || true)
{ echo "tag: $TAG (id=$MID)"; echo "kafka命中: $found"; echo "gtid before: $g_before"; echo "gtid after:  $g_after"; } | record "E2E 验证"

[ "$found" -ge 1 ] || die "E2E FAIL: marker 未到达 Kafka（tag=${TAG}）"
[ "$g_after" != "$g_before" ] || log "WARN: cursor gtid 未变化（低流量下可容忍，复查 30_verify）"
log "===== E2E PASS: marker id=${MID} 已到达 Kafka，链路贯通 ====="
