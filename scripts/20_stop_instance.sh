#!/usr/bin/env bash
# P2-1 停止 instance [门禁]
source "$(dirname "$0")/lib/common.sh"
log "===== P2-1 停止 instance ${DESTINATION} ====="

confirm "停止生产 instance ${DESTINATION}（链路暂停投递）" \
        "24_start_instance.sh 可随时重新启动"

# TODO: Admin API 端点实测后替换 admin_instance_op；临时替代：Admin UI 手工停止后回车继续
admin_instance_op stop || {
  read -r -p "Admin API 未实现。请在 Admin UI 手工停止 instance 后回车确认: " _
}

# 验证：停止后 dump 线程消失（日志不再滚动新的 parser 记录）
sleep 3
canal_logs --tail=5 | record "P2-1 停止后日志尾部"
log "===== P2-1 完成（人工核对上方日志确无新 dump 活动） ====="
