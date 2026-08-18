#!/usr/bin/env bash
# P2-5 启动 instance [门禁]。前置：22 已删 cursor、23 配置校验通过。
source "$(dirname "$0")/lib/common.sh"
log "===== P2-5 启动 instance ${DESTINATION} ====="

# 前置硬校验：cursor 必须不存在（存量位点会静默压制配置起点；zk_node_exists 为 SIGPIPE 安全实现）
if zk_node_exists "$CURSOR_PATH"; then
  die "cursor 节点仍存在！存量位点会压制 master.gtid，先执行 22_delete_cursor.sh"
fi

confirm "启动 instance ${DESTINATION}（将按配置的并集发起 GTID dump）" \
        "20_stop_instance.sh 停止；cursor 存档可恢复原位点"

# TODO: Admin API 端点实测后替换；临时替代：Admin UI 手工启动后回车继续
admin_instance_op start || {
  read -r -p "Admin API 未实现。请在 Admin UI 手工启动 instance 后回车确认: " _
}

sleep 10
canal_logs --tail=30 | grep -aiE "find start position|EntryPosition|1236" | record "P2-5 启动后寻位日志"
log "===== P2-5 完成，立即执行 30_verify.sh ====="
