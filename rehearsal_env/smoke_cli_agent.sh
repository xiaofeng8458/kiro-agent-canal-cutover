#!/usr/bin/env bash
# 跳板机执行：canal-cutover agent 配置验收（零风险）。
# 只信任 fs_read —— agent 拿不到 shell，无法执行任何命令；只验证：
#   定义能加载 / 提示词生效 / resources 可读 / 门禁规则已内化。
# 真正的行为验收（门禁点、失败即停、故障分诊）需要人在交互会话里做；
# permissions 生效性由 setup_cli_agent.sh §8 的 deny 冒烟探针把关。
# 前提：CLI v3（与 setup_cli_agent.sh 同一闸门逻辑，2.x 无 --v3 直接终止）。
set -uo pipefail
EU=/home/ec2-user
RB=$EU/canal_cutover_agent

pick_v3() {  # 输出可用的 v3 命令，找不到返回 1
  local bin ver
  for bin in kiro-cli kiro-cli-chat; do
    ver=$(sudo -u ec2-user -H env HOME=$EU PATH=$EU/.local/bin:/usr/local/bin:/usr/bin:/bin \
            $bin --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
    case "$ver" in
      3.*|[4-9]*.*) echo "$bin"; return 0 ;;
      2.*) sudo -u ec2-user -H env HOME=$EU PATH=$EU/.local/bin:/usr/local/bin:/usr/bin:/bin \
             $bin --v3 --version >/dev/null 2>&1 && { echo "$bin --v3"; return 0; } ;;
    esac
  done
  return 1
}
V3_CMD=$(pick_v3) || { echo "FATAL: 未找到 v3 CLI（3.x 或带 --v3 的 2.x）。permissions 门禁在 2.x 不执行，冒烟无意义。"; exit 1; }

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
  $V3_CMD chat --agent canal-cutover --no-interactive --trust-tools=fs_read "$Q" 2>&1 | tail -40
echo "=== 退出码=${PIPESTATUS[0]} ==="
