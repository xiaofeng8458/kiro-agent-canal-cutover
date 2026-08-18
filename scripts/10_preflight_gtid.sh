#!/usr/bin/env bash
# P1 GTID 预检（只读）：生成并集并验证其可被服务器接受。
# 用法：10_preflight_gtid.sh [旧GTID集合]   缺省用当前 cursor 的 gtid
source "$(dirname "$0")/lib/common.sh"
log "===== P1 GTID 预检 ====="

old_gtid="${1:-$(cursor_gtid)}"
[ -n "$old_gtid" ] || die "旧 GTID 集合为空"
purged=$(green_sql "SELECT @@global.gtid_purged")
log "旧集合    : $old_gtid"
log "gtid_purged: $purged"

# 并集 = GTID_SUBTRACT(旧 ∪ purged, '') 规范化；tr 去掉服务端输出里的换行/空格，保证单行
union=$(green_sql "SELECT GTID_SUBTRACT(CONCAT('${old_gtid}', ',', '${purged}'), '')" | tr -d '\n\r ')
echo "$union" > "$STATE_DIR/gtid_union.txt"
log "并集      : ${union}（已写入 state/gtid_union.txt）"

# 预检 1：purged ⊆ 并集（否则必然 1236）
c1=$(green_sql "SELECT GTID_SUBSET(@@global.gtid_purged, '${union}')")
# 预检 2：并集 ⊆ executed。注意：并集可能含服务端完全未知的外来 UUID（如旧环境只读副本
# 的本地事务），MySQL auto-positioning 对此容忍并忽略，不应判死——仅当并集在服务端
# 已知的 UUID 家系上超前于 executed 时才是真错误（会报 replica has more GTIDs）
c2=$(green_sql "SELECT GTID_SUBSET('${union}', @@global.gtid_executed)")
if [ "$c2" != "1" ]; then
  leftover=$(green_sql "SELECT GTID_SUBTRACT('${union}', @@global.gtid_executed)" | tr -d '\n\r ')
  bad=0
  for u in $(echo "$leftover" | tr ',' '\n' | cut -d: -f1 | sort -u); do
    known=$(green_sql "SELECT @@global.gtid_executed LIKE '%${u}%'")
    if [ "$known" = "1" ]; then log "FATAL: 并集在服务端已知家系 ${u} 上超前于 executed"; bad=1; fi
  done
  [ "$bad" = "1" ] && die "预检2失败：并集超前于服务端 executed"
  log "WARN: 并集含服务端未知的外来 UUID（${leftover}），按 MySQL 容忍规则放行"
  c2="tolerated"
fi
log "预检: purged⊆并集=$c1  并集⊆executed=$c2"
{ echo "old:    $old_gtid"; echo "purged: $purged"; echo "union:  $union"; echo "checks: $c1/$c2"; } | record "P1 预检结果"

[ "$c1" = "1" ] || die "GTID 预检未通过（purged 不含于并集），禁止进入 P2"
log "===== P1 通过，并集可用 ====="
