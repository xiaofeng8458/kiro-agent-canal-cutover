#!/usr/bin/env bash
# P3 验证循环（只读）。用法：30_verify.sh [观察分钟数，默认5]
source "$(dirname "$0")/lib/common.sh"
minutes="${1:-5}"
log "===== P3 验证（观察 ${minutes} 分钟） ====="

union=$(cat "$STATE_DIR/gtid_union.txt" 2>/dev/null) || die "未找到并集记录"

# 判据 1：起点正确 —— 寻位日志的 gtid 应等于并集
start_line=$(canal_logs --tail=200 | grep -a "find start position" | tail -1 || true)
log "寻位日志: ${start_line:-未找到（可能已滚动，继续按位点推进判定）}"
echo "$start_line" | grep -qF "$union" \
  && log "PASS 起点==并集" \
  || log "WARN 寻位日志未匹配并集，人工核对"

fail=0
prev_gtid=""
end=$(( $(date +%s) + minutes*60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  # 判据 2：无 1236 / RecordTooLarge
  errs=$(canal_logs --since=40s 2>/dev/null | grep -acE "errno = 1236|RecordTooLargeException" || true)
  if [ "$errs" -gt 0 ]; then
    canal_logs --since=40s | grep -aE "1236|RecordTooLarge|GTID set sent" | record "P3 异常日志"
    # 故障判定表：sent 与并集比对，区分"存量位点残留"与"并集过期"
    sent=$(canal_logs --since=40s | grep -a "GTID set sent by the replica" | tail -1 || true)
    log "FAIL 观察期出现错误。sent 行: ${sent:-无}"
    log "处置：sent≠并集 → 重走 P2-2 起（存量位点残留）；sent==并集 → 重跑 P1 重算并集"
    fail=1; break
  fi
  # 判据 3：位点单调推进
  cur_gtid=$(cursor_gtid || true)
  log "cursor gtid: ${cur_gtid:-读取失败}"
  if [ -n "$prev_gtid" ] && [ "$cur_gtid" = "$prev_gtid" ]; then
    log "WARN 位点 30s 未推进（低流量可为正常，连续多次需排查投递线程）"
  fi
  prev_gtid="$cur_gtid"
  sleep 30
done

# 判据 4：差值收敛 —— 只剩内部事务区间
if [ "$fail" -eq 0 ] && [ -n "$prev_gtid" ]; then
  diff=$(green_sql "SELECT GTID_SUBTRACT(@@global.gtid_executed, '${prev_gtid}')")
  log "executed − cursor 差值: $diff"
  echo "$diff" | record "P3 差值收敛检查"
fi

[ "$fail" -eq 0 ] && log "===== P3 通过（剩余人工项：源库写 marker → Kafka 侧确认到达） =====" \
                  || die "P3 未通过，按上方处置建议操作"
