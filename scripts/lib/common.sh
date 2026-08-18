#!/usr/bin/env bash
# 公共函数与环境加载。所有编号脚本 source 本文件。
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$LIB_DIR/../.." && pwd)"

ENV_FILE="$BASE_DIR/env.sh"
[ -f "$ENV_FILE" ] || { echo "FATAL: 未找到 ${ENV_FILE}（从 env.sh.sample 复制并填写）"; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

mkdir -p "$STATE_DIR"
RUN_LOG="$STATE_DIR/runbook_state.md"

log()    { echo "[$(date '+%F %T')] $*" | tee -a "$RUN_LOG"; }
die()    { log "FAIL: $*"; exit 1; }
record() { { echo ""; echo "## $(date '+%F %T') $1"; echo '```'; cat; echo '```'; } >> "$RUN_LOG"; }

# 门禁：打印计划，要求逐字输入 YES
confirm() {
  echo "=================================================="
  echo "即将执行变更操作：$1"
  echo "回滚方式        ：$2"
  echo "=================================================="
  read -r -p "输入 YES 确认执行（其他任意输入中止）: " ans
  [ "$ans" = "YES" ] || die "用户未确认，操作中止"
  log "GATE PASSED: $1"
}

# canal_manager 库查询（-N -B --raw：保留换行的裸输出）
mgr_sql() { mysql -h "$MGR_DB_HOST" -u "$MGR_DB_USER" -p"${MYSQL_PWD:?设置 MYSQL_PWD}" -N -B --raw -e "$1"; }

# 绿 RO 查询
green_sql() { mysql -h "$GREEN_RO_HOST" -u "$GREEN_RO_USER" -p"${MYSQL_PWD:?设置 MYSQL_PWD}" -N -B --raw -e "$1"; }

# zkCli（经 zk pod 非交互执行；输出含连接日志，调用方自行过滤）
zkcli() { kubectl -n "$ZK_NS" exec "$ZK_POD" -- zkCli.sh -server localhost:2181 "$@" 2>/dev/null; }

canal_logs() { kubectl -n "$NS" logs "$CANAL_POD" "$@"; }

# 读取 cursor JSON（zkCli get 输出的最后一行 JSON）
get_cursor() { zkcli get "$CURSOR_PATH" | grep -E '^\{' | tail -1; }

# 从 cursor JSON 提取 gtid 字段（注意 canal 源码错拼 "postion"）
cursor_gtid() { get_cursor | sed -E 's/.*"gtid":"([^"]*)".*/\1/'; }

# instance 启停走 Canal Admin REST API（UI 按钮背后的同一套接口）。
# 机制说明：admin 收到 API 请求后经 11110 管理通道直接向 server 下发指令；
# 直接翻转 DB status 字段对 cluster 实例无效（轮询只对配置行存在性敏感），勿用。
# 验证以 ZK running 节点为最终判据（存在=运行中）。
# 注意：不能写成 `zkcli stat | grep -q`——grep -q 命中即退出触发 SIGPIPE，
# pipefail 下管道返回 141，导致"存在"被误判为"不存在"。必须先捕获再判断。
zk_node_exists() {
  local out
  out=$(zkcli stat "$1" 2>/dev/null || true)
  echo "$out" | grep -q cZxid
}
zk_running() { zk_node_exists "/otter/canal/destinations/${DESTINATION}/running"; }

admin_token() {
  local tk_file="$STATE_DIR/.admin_token" resp tk
  if [ -s "$tk_file" ]; then cat "$tk_file"; return 0; fi
  resp=$(curl -s -m 8 -X POST "${ADMIN_API:?}/api/v1/user/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER:?}\",\"password\":\"${ADMIN_PASSWD:?需要 export ADMIN_PASSWD（Admin UI 密码）}\"}")
  tk=$(echo "$resp" | jq -r '.data.token // empty')
  [ -n "$tk" ] || { echo "Admin 登录失败: $(echo "$resp" | head -c 200)" >&2; return 1; }
  printf '%s' "$tk" > "$tk_file"; chmod 600 "$tk_file"
  printf '%s' "$tk"
}

admin_instance_id() {
  curl -s -m 8 -H "X-Token: $1" "${ADMIN_API}/api/v1/canal/instances?page=1&name=${DESTINATION}" \
    | jq -r --arg n "$DESTINATION" '.data.items[]? | select(.name==$n) | .id' | head -1
}

admin_instance_op() {
  local op="$1" want tk id resp code tries=0
  case "$op" in
    status) if zk_running; then echo running; else echo stopped; fi; return 0 ;;
    start)  want=present ;;
    stop)   want=absent ;;
    *) echo "unknown op: $op" >&2; return 1 ;;
  esac
  tk=$(admin_token) || return 1
  id=$(admin_instance_id "$tk")
  if [ -z "$id" ]; then  # 缓存 token 可能过期：强制重登后重试一次
    rm -f "$STATE_DIR/.admin_token"
    tk=$(admin_token) || return 1
    id=$(admin_instance_id "$tk")
  fi
  [ -n "$id" ] || { echo "Admin API 查不到 instance ${DESTINATION}" >&2; return 1; }
  resp=$(curl -s -m 8 -X PUT -H "X-Token: $tk" "${ADMIN_API}/api/v1/canal/instance/status/${id}?option=${op}")
  code=$(echo "$resp" | jq -r '.code // empty')
  if [ "$code" != "20000" ]; then  # token 过期则重登一次
    rm -f "$STATE_DIR/.admin_token"; tk=$(admin_token) || return 1
    resp=$(curl -s -m 8 -X PUT -H "X-Token: $tk" "${ADMIN_API}/api/v1/canal/instance/status/${id}?option=${op}")
    code=$(echo "$resp" | jq -r '.code // empty')
  fi
  [ "$code" = "20000" ] || { echo "Admin API ${op} 失败: $(echo "$resp" | head -c 200)" >&2; return 1; }
  log "Admin API ${op} 已下发（instance id=${id}），等待 ZK 确认..."
  while [ $tries -lt 12 ]; do
    sleep 5; tries=$((tries+1))
    if [ "$want" = absent ]  && ! zk_running; then log "instance ${DESTINATION} 已停止（ZK running 消失）"; return 0; fi
    if [ "$want" = present ] &&   zk_running; then log "instance ${DESTINATION} 已启动（ZK running 出现）"; return 0; fi
  done
  echo "WARN: ${op} 已下发但 60s 内 ZK 未达预期，走人工确认" >&2
  return 1
}
admin_get_config()    { mgr_sql "SELECT content FROM canal_manager.canal_instance_config WHERE name='${DESTINATION}'"; }
