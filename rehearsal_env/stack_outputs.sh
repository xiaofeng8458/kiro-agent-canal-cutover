#!/usr/bin/env bash
# 本地执行：从 CloudFormation 栈 Outputs 导出演练环境标识，供其余脚本使用。
# 仓库内**不硬编码任何环境标识**，一切以本次部署的栈 Outputs 为准。
#
# 用法（注意是 source，不是直接执行）：
#   source ./stack_outputs.sh              # 默认栈名 CanalRehearsalStack，区域 us-east-1
#   STACK=MyStack REGION=us-west-2 source ./stack_outputs.sh
#
# 导出：BASTION_ID / PRIMARY_ENDPOINT / READER_ENDPOINT / DB_SECRET_NAME / MSK_CLUSTER_ARN

_STACK=${STACK:-CanalRehearsalStack}
_REGION=${REGION:-us-east-1}

_out() {
  aws cloudformation describe-stacks --stack-name "$_STACK" --region "$_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

export REGION="$_REGION"
export AWS_REGION="$_REGION"
export BASTION_ID="$(_out BastionId)"
export PRIMARY_ENDPOINT="$(_out PrimaryEndpoint)"
export READER_ENDPOINT="$(_out ReaderEndpoint)"
export DB_SECRET_NAME="$(_out DbSecretName)"
export MSK_CLUSTER_ARN="$(_out MskClusterArn)"

if [ -z "$BASTION_ID" ] || [ "$BASTION_ID" = "None" ]; then
  echo "!! 取不到栈 $_STACK（区域 $_REGION）的 Outputs。先确认 cdk deploy 已完成、凭证与区域正确。" >&2
else
  printf '%-18s %s\n' \
    STACK            "$_STACK ($_REGION)" \
    BASTION_ID       "$BASTION_ID" \
    PRIMARY_ENDPOINT "$PRIMARY_ENDPOINT" \
    READER_ENDPOINT  "$READER_ENDPOINT" \
    DB_SECRET_NAME   "$DB_SECRET_NAME" \
    MSK_CLUSTER_ARN  "$MSK_CLUSTER_ARN"
fi

unset _STACK _REGION
