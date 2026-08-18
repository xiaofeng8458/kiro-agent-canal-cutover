#!/usr/bin/env bash
# 造数端：持续写 marker（数据连续性验证的基准流量）。仅写测试表 MARKER_TABLE，可自主执行。
# 用法: 40_loadgen.sh start [间隔秒,默认2] | stop | status
source "$(dirname "$0")/lib/common.sh"

BIZ_DB_HOST="${BIZ_DB_HOST:-$MGR_DB_HOST}"
BIZ_DB_USER="${BIZ_DB_USER:-$MGR_DB_USER}"
MARKER_TABLE="${MARKER_TABLE:-biz_test.marker}"
PIDFILE="$STATE_DIR/loadgen.pid"
export LOADGEN_ERR="$STATE_DIR/loadgen.err"

biz_sql() { mysql -h "$BIZ_DB_HOST" -u "$BIZ_DB_USER" -p"${MYSQL_PWD:?设置 MYSQL_PWD}" -N -B -e "$1"; }

case "${1:-status}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      log "造数端已在运行 pid=$(cat "$PIDFILE")"; exit 0
    fi
    : "${MYSQL_PWD:?需要 export MYSQL_PWD}"
    export BIZ_DB_HOST BIZ_DB_USER MARKER_TABLE MYSQL_PWD
    export INTERVAL="${2:-2}"
    setsid nohup bash -c '
      while true; do
        mysql -h "$BIZ_DB_HOST" -u "$BIZ_DB_USER" \
          -e "INSERT INTO ${MARKER_TABLE}(tag) VALUES (CONCAT(\"load-\", NOW(6)))" 2>>"$LOADGEN_ERR"
        sleep "$INTERVAL"
      done' >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3
    log "造数端已启动 pid=$(cat "$PIDFILE") 间隔=${INTERVAL}s 当前MAX(id)=$(biz_sql "SELECT MAX(id) FROM ${MARKER_TABLE}")"
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      log "造数端已停止"
    else
      log "造数端未在运行（无 pid 文件）"
    fi
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      m1=$(biz_sql "SELECT MAX(id) FROM ${MARKER_TABLE}"); sleep 5
      m2=$(biz_sql "SELECT MAX(id) FROM ${MARKER_TABLE}")
      log "运行中 pid=$(cat "$PIDFILE")  MAX(id): ${m1} -> ${m2} $([ "$m2" -gt "$m1" ] 2>/dev/null && echo '(推进中)' || echo '(未推进,查 loadgen.err)')"
      tail -2 "$LOADGEN_ERR" 2>/dev/null || true
    else
      log "未在运行"
    fi
    ;;
  *) die "用法: $0 start [间隔秒] | stop | status" ;;
esac
