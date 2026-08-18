#!/usr/bin/env bash
# P2-3 删除 cursor 节点 [门禁]。前置：20 已停止 instance、21 已存档。
source "$(dirname "$0")/lib/common.sh"
log "===== P2-3 删除 cursor 节点 ====="

ls "$STATE_DIR"/cursor_backup_*.json >/dev/null 2>&1 || die "未找到 cursor 存档，先执行 21_archive_cursor.sh"

confirm "删除 ZK 节点 ${CURSOR_PATH}" \
        "用 state/ 下最新的 cursor_backup_*.json 通过 zkCli create/set 恢复"

zkcli deleteall "$CURSOR_PATH" || zkcli rmr "$CURSOR_PATH" || die "删除失败（deleteall 与 rmr 均不可用）"

# 验证：节点必须不存在（zk_node_exists 为 SIGPIPE 安全实现）
if zk_node_exists "$CURSOR_PATH"; then
  die "cursor 节点仍存在，删除未生效"
fi
log "===== P2-3 完成，cursor 已删除 ====="
