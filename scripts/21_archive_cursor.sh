#!/usr/bin/env bash
# P2-2 存档 cursor（只读）。必须在 instance 停止后执行，读到的才是精确终值。
source "$(dirname "$0")/lib/common.sh"
log "===== P2-2 存档 cursor ====="

cur=$(get_cursor); [ -n "$cur" ] || die "读不到 cursor: $CURSOR_PATH"
ts=$(date +%Y%m%d_%H%M%S)
echo "$cur" > "$STATE_DIR/cursor_backup_${ts}.json"
echo "$cur" | record "P2-2 cursor 存档 (cursor_backup_${ts}.json)"
log "gtid 终值: $(cursor_gtid)"
log "===== P2-2 完成，存档于 state/cursor_backup_${ts}.json ====="
