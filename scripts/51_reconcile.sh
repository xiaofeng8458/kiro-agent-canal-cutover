#!/usr/bin/env bash
# 数据完整性对账：源表 id 集合 vs Kafka 消费到的 id 集合。
# 判定标准：Kafka ⊇ 源表（允许重复，不允许缺失）。只读 + Kafka 消费，可自主执行。
# 用法: 51_reconcile.sh [Kafka消费等待秒,默认60]
source "$(dirname "$0")/lib/common.sh"

BIZ_DB_HOST="${BIZ_DB_HOST:-$MGR_DB_HOST}"
BIZ_DB_USER="${BIZ_DB_USER:-$MGR_DB_USER}"
MARKER_TABLE="${MARKER_TABLE:-biz_test.marker}"
WAIT="${1:-60}"
: "${KAFKA_BROKERS:?env.sh 需配置 KAFKA_BROKERS}"
: "${KAFKA_TOPIC:?env.sh 需配置 KAFKA_TOPIC}"
TBL="${MARKER_TABLE##*.}"

biz_sql() { mysql -h "$BIZ_DB_HOST" -u "$BIZ_DB_USER" -p"${MYSQL_PWD:?设置 MYSQL_PWD}" -N -B -e "$1"; }

log "===== 数据完整性对账 ====="
DB_IDS="$STATE_DIR/reconcile_db_ids.txt"
KF_RAW="$STATE_DIR/reconcile_kafka_raw.txt"
KF_IDS="$STATE_DIR/reconcile_kafka_ids.txt"

log "1. 源表 id 集合"
biz_sql "SELECT id FROM ${MARKER_TABLE} ORDER BY id" | sort > "$DB_IDS"
log "   源表: $(wc -l < "$DB_IDS") 行, id 范围 $(biz_sql "SELECT MIN(id), MAX(id) FROM ${MARKER_TABLE}")"

log "2. 全量消费 Kafka（topic=${KAFKA_TOPIC}，等待 ${WAIT}s）"
kubectl delete pod kafka-reconcile --ignore-not-found >/dev/null 2>&1
kubectl run kafka-reconcile --restart=Never --image=apache/kafka:3.7.0 -- sh -c \
  "/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server ${KAFKA_BROKERS} --topic ${KAFKA_TOPIC} --from-beginning --timeout-ms $((WAIT*1000)) 2>/dev/null" >/dev/null
for i in $(seq 1 $((WAIT+40))); do
  ph=$(kubectl get pod kafka-reconcile -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$ph" in Succeeded|Failed) break;; esac
  sleep 2
done
kubectl logs kafka-reconcile 2>/dev/null | grep -a '^{' > "$KF_RAW" || true
kubectl delete pod kafka-reconcile >/dev/null 2>&1

jq -r --arg t "$TBL" 'select(.table==$t and .type=="INSERT") | .data[]?.id' "$KF_RAW" 2>/dev/null > "$KF_IDS.all" || true
sort "$KF_IDS.all" | uniq > "$KF_IDS"
total_msgs=$(wc -l < "$KF_RAW"); total_ids=$(wc -l < "$KF_IDS.all"); uniq_ids=$(wc -l < "$KF_IDS")
dup=$((total_ids - uniq_ids))

log "   Kafka: 消息 ${total_msgs} 条, INSERT id ${total_ids} 个（去重 ${uniq_ids}，重复 ${dup}——at-least-once 属预期）"

log "3. 判定"
missing=$(comm -23 "$DB_IDS" "$KF_IDS")
miss_n=$(echo "$missing" | grep -c . || true)
{ echo "源表: $(wc -l < "$DB_IDS")  kafka去重: $uniq_ids  重复: $dup  缺失: $miss_n"
  [ "$miss_n" -gt 0 ] && { echo "缺失 id（数值排序，前 20）:"; echo "$missing" | sort -n | head -20; }
} | record "对账结果"

if [ "$miss_n" -eq 0 ]; then
  log "===== 对账 PASS: 零缺失（重复 ${dup} 条由下游幂等吸收） ====="
else
  log "缺失 id 数值范围: $(echo "$missing" | sort -n | head -1) ~ $(echo "$missing" | sort -n | tail -1)"
  die "对账 FAIL: 缺失 ${miss_n} 个 id（对照故障时间线判断是否为已知丢失窗口，如 retention 未继承的处置窗口）"
fi
