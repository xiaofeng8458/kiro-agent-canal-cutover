#!/usr/bin/env bash
# 演练环境清理脚本（在本地有 AWS 凭证的机器上执行，不是跳板机——跳板机自己也会被删）
#
# 用法:
#   ./cleanup.sh              # 缺省 dry-run：只盘点将被删除的资源，不动任何东西
#   ./cleanup.sh --execute    # 真正删除（需输入确认短语）
#
# 删除范围（按依赖顺序）：
#   1. Blue/Green 部署对象（不删 target）
#   2. 非栈管理的孤儿实例中「本身是只读副本」的那些 —— 必须先删，否则它们的源实例删不掉
#   3. CloudFormation 栈 CanalRehearsalStack（EKS/RDS/MSK/跳板机/SG/Secret，约 30-45 分钟）
#   4. 剩余孤儿实例（此时其副本已随栈消失，可删）
#   5. 8.4 参数组 canal-rehearsal-84（栈删完、无实例引用后才可删）
#   6. EKS 动态供给的孤儿 EBS 卷（ZK PVC 残留，栈删除不会优雅回收）
#   7. CloudWatch 日志组（RDS error log / CDK provider Lambda 日志）
#
# ⚠️ 为什么不再按 "-old1" 名字匹配（2026-08-15 演练实测教训）：
# RDS Blue/Green switchover **可能只有主库成员成功、副本成员 SWITCHOVER_FAILED**
# （聚合状态仍报 SWITCHOVER_COMPLETED，极具误导性）。此时名字与归属会交叉：
#   - 栈跟踪的 "primary" 物理 ID 变成了绿的 8.4 实例
#   - 栈跟踪的 "reader" 物理 ID 仍是旧的 8.0 副本（名字没搬走）
#   - 绿副本保留 "-green-xxxx" 后缀，既不在栈里、也不含 "-old1" → 按旧逻辑会被漏掉
# 因此改为：用「栈资源的物理 ID」作为唯一权威来区分 栈管理 vs 孤儿，
# 并按 副本先于源 的依赖顺序删除。
#
# 不会触碰：部署时用 -c vpcId 指定的那个现有 VPC 及其子网/NAT——非本栈资源
#
# ⚠️ 执行前确认：51 对账已完成、跳板机 state/ 证据已拉回本地、演练报告已提交
set -uo pipefail

REGION=us-east-1
STACK=CanalRehearsalStack
BG_NAME=canal-rehearsal-bg
PG_NAME=canal-rehearsal-84
EKS_CLUSTER=canal-rehearsal
NAME_PREFIX=canalrehearsalstack

MODE=dryrun
[ "${1:-}" = "--execute" ] && MODE=execute

say() { echo "[$(date '+%H:%M:%S')] $*"; }
run() { if [ "$MODE" = execute ]; then "$@"; else echo "  (dry-run) $*"; fi; }

echo "==================== 资源盘点 ===================="

# 1. B/G 部署对象
BGID=$(aws rds describe-blue-green-deployments --region $REGION \
  --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].BlueGreenDeploymentIdentifier" \
  --output text 2>/dev/null)
say "B/G 部署: ${BGID:-无}"

# 2. CloudFormation 栈（先取，孤儿判定要用它的物理 ID）
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $STACK --region $REGION \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
say "栈 $STACK: ${STACK_STATUS:-不存在}"

# 3. 区分 栈管理 vs 孤儿（权威依据是栈资源的物理 ID，不是名字里有没有 -old1）
STACK_DBS=$(aws cloudformation describe-stack-resources --stack-name $STACK --region $REGION \
  --query "StackResources[?ResourceType=='AWS::RDS::DBInstance'].PhysicalResourceId" \
  --output text 2>/dev/null | tr '\t' '\n' | grep . || true)
ALL_DBS=$(aws rds describe-db-instances --region $REGION \
  --query "DBInstances[?contains(DBInstanceIdentifier,'$NAME_PREFIX')].DBInstanceIdentifier" \
  --output text 2>/dev/null | tr '\t' '\n' | grep . || true)

ORPHAN_REPLICAS=""; ORPHAN_ROOTS=""
for db in $ALL_DBS; do
  echo "$STACK_DBS" | grep -qx "$db" && continue          # 栈管理，交给 CFN
  src=$(aws rds describe-db-instances --db-instance-identifier "$db" --region $REGION \
        --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text 2>/dev/null)
  if [ -n "$src" ] && [ "$src" != "None" ]; then
    ORPHAN_REPLICAS="$ORPHAN_REPLICAS $db"               # 副本：必须先删
  else
    ORPHAN_ROOTS="$ORPHAN_ROOTS $db"                     # 源：等栈删完再删
  fi
done
say "栈管理实例  : $(echo $STACK_DBS | tr '\n' ' ')"
say "孤儿(副本)  :${ORPHAN_REPLICAS:- 无}   ← 阻塞其源实例删除，先删"
say "孤儿(源)    :${ORPHAN_ROOTS:- 无}      ← 栈删完后再删"

# 4. 参数组
PG_EXISTS=$(aws rds describe-db-parameter-groups --db-parameter-group-name $PG_NAME --region $REGION \
  --query 'DBParameterGroups[0].DBParameterGroupName' --output text 2>/dev/null)
say "参数组: ${PG_EXISTS:-无}"

# 5. 孤儿 EBS 卷（EKS 动态供给）
ORPHAN_VOLS=$(aws ec2 describe-volumes --region $REGION \
  --filters "Name=status,Values=available" "Name=tag:kubernetes.io/cluster/$EKS_CLUSTER,Values=owned" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null)
say "孤儿 EBS 卷: ${ORPHAN_VOLS:-无（栈删除后再跑一次本脚本清理）}"

# 6. 日志组
LOG_GROUPS=$( { aws logs describe-log-groups --region $REGION --log-group-name-prefix "/aws/rds/instance/$NAME_PREFIX" --query 'logGroups[].logGroupName' --output text; \
                aws logs describe-log-groups --region $REGION --log-group-name-prefix "/aws/lambda/$STACK" --query 'logGroups[].logGroupName' --output text; } 2>/dev/null | tr '\t' '\n' | grep . )
say "日志组: $(echo "$LOG_GROUPS" | grep -c . || echo 0) 个"

if [ "$MODE" = dryrun ]; then
  echo
  echo "dry-run 结束。真正删除请运行: $0 --execute"
  exit 0
fi

echo
echo "⚠️  以上资源将被永久删除（RDS 跳过最终快照）。VPC 不受影响。预计 30-60 分钟。"
read -r -p "输入 DELETE-REHEARSAL 确认: " ans
[ "$ans" = "DELETE-REHEARSAL" ] || { echo "未确认，退出"; exit 1; }

echo "==================== 执行删除 ===================="

# 1. B/G 部署对象（保留 target）
if [ -n "$BGID" ] && [ "$BGID" != "None" ]; then
  say "删除 B/G 部署 $BGID ..."
  run aws rds delete-blue-green-deployment --blue-green-deployment-identifier "$BGID" --region $REGION
  while aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$BGID" --region $REGION >/dev/null 2>&1; do
    sleep 15; say "  等待 B/G 对象删除..."
  done
fi

# 2. 孤儿副本：必须先删，否则它们的源实例（可能是栈管理的）删不掉
for inst in $ORPHAN_REPLICAS; do
  say "删除孤儿副本 $inst ..."
  run aws rds delete-db-instance --db-instance-identifier "$inst" \
    --skip-final-snapshot --delete-automated-backups --region $REGION >/dev/null
  say "  等待 $inst 删除完成..."
  [ "$MODE" = execute ] && { aws rds wait db-instance-deleted --db-instance-identifier "$inst" --region $REGION 2>/dev/null || true; }
done

# 3. CloudFormation 栈
if [ -n "$STACK_STATUS" ] && [ "$STACK_STATUS" != "None" ]; then
  say "删除栈 ${STACK}（约 30-45 分钟，MSK/EKS 是长杆）..."
  # ⚠️ 2026-08-15 实测教训：delete-stack 因本地网络瞬断而失败时，原实现把错误吞掉，
  # 轮询随后一直读到 CREATE_COMPLETE，脚本"看起来在删"实际空转了 1.5 小时且资源持续计费。
  # 现在：delete-stack 失败即重试，并强制确认栈真的离开了 CREATE/UPDATE_COMPLETE 态，否则报错退出。
  if [ "$MODE" = execute ]; then
    for attempt in 1 2 3; do
      if aws cloudformation delete-stack --stack-name $STACK --region $REGION; then break; fi
      say "  delete-stack 调用失败（第 ${attempt} 次），10s 后重试..."
      sleep 10
      [ $attempt -eq 3 ] && { say "  ❌ delete-stack 连续 3 次调用失败（网络/凭证？），中止——资源未删除"; exit 1; }
    done
    # 删除请求必须在 90s 内体现为状态变化，否则说明请求没生效
    ACCEPTED=0
    for _ in $(seq 1 18); do
      ST=$(aws cloudformation describe-stacks --stack-name $STACK --region $REGION \
        --query 'Stacks[0].StackStatus' --output text 2>&1)
      case "$ST" in
        *"does not exist"*|DELETE_IN_PROGRESS|DELETE_COMPLETE|DELETE_FAILED) ACCEPTED=1; break ;;
      esac
      sleep 5
    done
    [ "$ACCEPTED" = 1 ] || { say "  ❌ 删除请求未生效（栈仍为 ${ST}），中止以免空转"; exit 1; }
    say "  删除请求已生效，开始轮询"
  else
    run aws cloudformation delete-stack --stack-name $STACK --region $REGION
  fi
  while :; do
    ST=$(aws cloudformation describe-stacks --stack-name $STACK --region $REGION \
      --query 'Stacks[0].StackStatus' --output text 2>&1)
    case "$ST" in
      *"does not exist"*) say "  栈已删除"; break ;;
      DELETE_FAILED) say "  ⚠️ DELETE_FAILED——查看控制台事件定位卡住的资源后重跑本脚本"; break ;;
      CREATE_COMPLETE|UPDATE_COMPLETE) say "  ❌ 栈回到 ${ST}，删除未在进行，中止"; exit 1 ;;
      *"Could not connect"*|*"error occurred"*) say "  查询失败（${ST}），30s 后重试"; sleep 30 ;;
      *) say "  $ST"; sleep 120 ;;
    esac
  done
fi

# 3.5 剩余孤儿源实例（其副本已随栈删除，现在可删）
for inst in $ORPHAN_ROOTS; do
  say "删除孤儿源实例 $inst ..."
  run aws rds delete-db-instance --db-instance-identifier "$inst" \
    --skip-final-snapshot --delete-automated-backups --region $REGION >/dev/null
  say "  等待 $inst 删除完成..."
  [ "$MODE" = execute ] && { aws rds wait db-instance-deleted --db-instance-identifier "$inst" --region $REGION 2>/dev/null || true; }
done

# 4. 参数组
if [ -n "$PG_EXISTS" ] && [ "$PG_EXISTS" != "None" ]; then
  say "删除参数组 $PG_NAME ..."
  run aws rds delete-db-parameter-group --db-parameter-group-name $PG_NAME --region $REGION \
    || say "  ⚠️ 删除失败（仍被实例引用？等栈删完后重跑本脚本）"
fi

# 5. 孤儿 EBS 卷（栈删完后重新扫描一次）
VOLS=$(aws ec2 describe-volumes --region $REGION \
  --filters "Name=status,Values=available" "Name=tag:kubernetes.io/cluster/$EKS_CLUSTER,Values=owned" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null)
for v in $VOLS; do
  say "删除孤儿卷 $v ..."
  run aws ec2 delete-volume --volume-id "$v" --region $REGION
done

# 6. 日志组
for lg in $LOG_GROUPS; do
  say "删除日志组 $lg ..."
  run aws logs delete-log-group --log-group-name "$lg" --region $REGION || true
done

echo "==================== 终检 ===================="
aws rds describe-db-instances --region $REGION \
  --query "DBInstances[?contains(DBInstanceIdentifier,'$NAME_PREFIX')].DBInstanceIdentifier" --output text | grep . \
  && say "⚠️ 仍有 RDS 实例残留" || say "RDS: 清"
aws kafka list-clusters --region $REGION --cluster-name-filter $EKS_CLUSTER \
  --query 'ClusterInfoList[0].State' --output text 2>/dev/null | grep -v None | grep . \
  && say "⚠️ MSK 残留" || say "MSK: 清"
aws eks describe-cluster --name $EKS_CLUSTER --region $REGION >/dev/null 2>&1 \
  && say "⚠️ EKS 残留" || say "EKS: 清"
say "完成。建议次日在 Cost Explorer 复核该区域费用归零。"
