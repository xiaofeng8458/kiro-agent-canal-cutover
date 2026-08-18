#!/usr/bin/env bash
# P2-4 校验 instance 配置（只读）。master.gtid 的修改在 Admin UI 完成，本脚本回读 DB 逐项核验。
source "$(dirname "$0")/lib/common.sh"
log "===== P2-4 校验 master.gtid 配置 ====="

union=$(cat "$STATE_DIR/gtid_union.txt" 2>/dev/null) || die "未找到并集，先执行 10_preflight_gtid.sh"
cfg=$(admin_get_config)

# 1. key 恰好出现一次
cnt=$(echo "$cfg" | grep -cE "^\s*canal\.instance\.master\.gtid\s*=" || true)
[ "$cnt" -eq 1 ] || die "master.gtid 出现 $cnt 次（应恰为 1），在 Admin UI 清理重复/缺失行"

# 2. 值与并集逐字一致（单行；properties 中换行即截断）
val=$(echo "$cfg" | grep -E "^\s*canal\.instance\.master\.gtid\s*=" | sed -E 's/^[^=]*=\s*//')
log "配置值: $val"
log "期望值: $union"
[ "$val" = "$union" ] || die "配置值与并集不一致（检查换行截断/空格/是否已保存）"

# 3. gtidon 必须为 true；journal/position 应为空
echo "$cfg" | grep -E "gtidon|journal\.name|master\.position" | record "P2-4 相关配置行"
echo "$cfg" | grep -qE "^\s*canal\.instance\.gtidon\s*=\s*true" || die "gtidon 不是 true"

# 4. TSDB 启用时（模板默认），master.gtid 播种必须配套 master.timestamp > 0（canal 硬校验）
if ! echo "$cfg" | grep -qE "^\s*canal\.instance\.tsdb\.enable\s*=\s*false"; then
  ts=$(echo "$cfg" | grep -E "^\s*canal\.instance\.master\.timestamp\s*=" | sed -E 's/^[^=]*=\s*//' | tr -d ' ')
  case "$ts" in
    ''|*[!0-9]*) die "TSDB 启用而 master.timestamp 缺失/非法（canal 将报 use gtid and TableMeta TSDB should be config timestamp > 0）" ;;
    0) die "master.timestamp 不能为 0" ;;
    *) log "master.timestamp: $ts" ;;
  esac
fi

log "===== P2-4 通过，配置与并集一致 ====="
