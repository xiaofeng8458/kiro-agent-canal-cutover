#!/usr/bin/env bash
# P0 环境断言（只读）。任一断言失败即退出，禁止带病进入后续阶段。
source "$(dirname "$0")/lib/common.sh"
log "===== P0 环境断言 ====="

# 1. Pod 现状：canal-server×1 运行中
pods=$(kubectl -n "$NS" get pods --no-headers | grep canal)
echo "$pods" | record "P0-1 pod 现状"
echo "$pods" | grep -q "^${CANAL_POD}.*Running" || die "canal-server pod 不在 Running 状态"

# 2. 位点模式必须是 default-instance.xml（ZK）
spring_xml=$(mgr_sql "SELECT content FROM canal_manager.canal_config WHERE name='canal.properties'" \
  | grep -E "^\s*canal\.instance\.global\.spring\.xml" | tail -1)
log "P0-2 spring.xml: $spring_xml"
echo "$spring_xml" | grep -q "default-instance.xml" || die "位点模式非 ZK，本 runbook 不适用"

# 3. master.gtid 配置健康度：key 恰好出现 0 或 1 次（>1 为重复 key 隐患）
cnt=$(admin_get_config | grep -cE "^\s*canal\.instance\.master\.gtid" || true)
log "P0-3 master.gtid 行数: $cnt"
[ "$cnt" -le 1 ] || die "instance 配置存在 $cnt 行 master.gtid（重复 key），先在 Admin UI 清理"

# 4. ZK 连接对账：canal pod IP 必须出现在 zk 的客户端连接里
canal_ip=$(kubectl -n "$NS" get pod "$CANAL_POD" -o jsonpath='{.status.podIP}')
cons=$(kubectl -n "$ZK_NS" exec "$ZK_POD" -- sh -c 'echo cons | nc localhost 2181')
echo "$cons" | record "P0-4 zk 连接对账 (canal_ip=$canal_ip)"
echo "$cons" | grep -q "$canal_ip" || die "canal pod ($canal_ip) 未连接在这台 ZK 上，ensemble 错位"

# 5. cursor 节点可读，当前值存档
cur=$(get_cursor); [ -n "$cur" ] || die "读不到 cursor 节点: $CURSOR_PATH"
echo "$cur" | record "P0-5 当前 cursor"
log "P0-5 当前 gtid: $(cursor_gtid)"

log "===== P0 全部通过 ====="
