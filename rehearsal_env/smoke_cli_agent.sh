#!/usr/bin/env bash
# 跳板机执行：canal-cutover agent 配置验收（零风险）。
# 只信任 fs_read —— agent 拿不到 shell，无法执行任何命令；只验证：
#   定义能加载 / 提示词生效 / resources 可读 / 门禁规则已内化。
# 真正的行为验收（门禁点、失败即停、故障分诊）需要人在交互会话里做。
set -uo pipefail
EU=/home/ec2-user
RB=$EU/canal_cutover_agent

read -r -d '' Q <<'EOF'
只回答问题，不要执行任何命令。依据 runbook 回答三点，每点一行：
1) 哪些脚本属于"变更脚本"（列脚本名）；
2) 执行变更脚本之前你必须先向我出示哪三项内容；
3) RDS Blue/Green switchover 的触发由谁执行。
EOF

cd "$RB"
sudo -u ec2-user -H env HOME=$EU \
  PATH=$EU/.local/bin:/usr/local/bin:/usr/bin:/bin \
  AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 \
  KUBECONFIG=$EU/.kube/config \
  kiro-cli-chat chat --agent canal-cutover --no-interactive --trust-tools=fs_read "$Q" 2>&1 | tail -40
echo "=== 退出码=${PIPESTATUS[0]} ==="
