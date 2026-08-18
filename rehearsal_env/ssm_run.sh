#!/usr/bin/env bash
# 经 SSM send-command 在跳板机上执行 shell（本地无需 SSH，也不需要交互式 session）。
# 用法: ./ssm_run.sh 'kubectl get nodes'
#      ./ssm_run.sh -f script.sh          # 把本地脚本内容整段送上去执行
# 环境变量：
#   BASTION_ID  必填。栈 Outputs 的 BastionId；也可先 `source ./stack_outputs.sh` 自动导出
#   REGION      默认 us-east-1
#   TIMEOUT     默认 600 秒
set -uo pipefail

REGION=${REGION:-us-east-1}
TIMEOUT=${TIMEOUT:-600}
: "${BASTION_ID:?需要 export BASTION_ID=<栈 Outputs 的 BastionId>，或先 source ./stack_outputs.sh}"

ARGS=""
if [ "${1:-}" = "-f" ]; then
  BODY=$(cat "$2")
  shift 2
  # 把余下参数转发给被送入的脚本（$1/$2... 在远端可见）
  for a in "$@"; do ARGS="$ARGS $(printf '%q' "$a")"; done
  [ -n "$ARGS" ] && ARGS="set --$ARGS"
else
  BODY="$1"
fi

# SSM RunShellScript 以 root 跑但 HOME 不是 /root，kubectl 会退回 localhost:8080。
# 统一前导：固定 HOME/KUBECONFIG/AWS_REGION/PATH。
PREAMBLE='export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION='"$REGION"'
export AWS_DEFAULT_REGION='"$REGION"'
export PATH=/usr/local/bin:/usr/bin:/bin:$PATH'

# 环境标识透传：本地 source stack_outputs.sh 后，这些值随命令一起送到远端，
# 远端脚本因此不需要硬编码任何 endpoint / secret 名 / ARN。
# 只透传非敏感的资源标识——**口令一律不经这里传递**（远端自行从 Secrets Manager 取）。
for v in PRIMARY_ENDPOINT READER_ENDPOINT DB_SECRET_NAME MSK_CLUSTER_ARN \
         GREEN_READER_ENDPOINT OLD_CURSOR_GTID ARCHIVED_TS; do
  val=$(eval "printf '%s' \"\${$v:-}\"")
  [ -n "$val" ] && PREAMBLE="$PREAMBLE
export $v=$(printf '%q' "$val")"
done

SCRIPT="$PREAMBLE
$ARGS
$BODY"

CID=$(aws ssm send-command --region "$REGION" \
  --instance-ids "$BASTION_ID" \
  --document-name AWS-RunShellScript \
  --comment "canal rehearsal ops" \
  --timeout-seconds "$TIMEOUT" \
  --parameters "$(python3 -c '
import json,sys
print(json.dumps({"commands":[sys.stdin.read()],"executionTimeout":["'"$TIMEOUT"'"]}))
' <<<"$SCRIPT")" \
  --query 'Command.CommandId' --output text) || exit 1

for _ in $(seq 1 "$TIMEOUT"); do
  ST=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CID" --instance-id "$BASTION_ID" \
    --query 'Status' --output text 2>/dev/null)
  case "$ST" in
    Success|Failed|Cancelled|TimedOut) break ;;
    *) sleep 3 ;;
  esac
done

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CID" --instance-id "$BASTION_ID" \
  --query '{Status:Status,Code:ResponseCode,Out:StandardOutputContent,Err:StandardErrorContent}' \
  --output json | python3 -c '
import json,sys
d = json.load(sys.stdin)
print("[status=%s exit=%s]" % (d["Status"], d["Code"]))
if d.get("Out"):
    print(d["Out"], end="")
if d.get("Err"):
    print("--- stderr ---")
    print(d["Err"], end="")
'
