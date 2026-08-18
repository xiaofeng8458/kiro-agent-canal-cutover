#!/usr/bin/env bash
# 跳板机执行（以 root 送入，内部切 ec2-user）：为 kiro-cli 配置 canal-cutover agent。
#
# 背景：kiro-cli 装在 ec2-user 下（/home/ec2-user/.local/bin），登录态在
# /home/ec2-user/.kiro；而 runbook 资产与口令原先在 /root。agent 会话以 ec2-user 身份
# 运行，读不到 /root。故把 runbook 操作身份统一到 ec2-user：
#   - 口令唯一权威位置 /home/ec2-user/.canal/secrets.sh（600, ec2-user；root 天然可读）
#   - /root/canal_env.sh 与 /root/msk_env.sh 退化为 shim，现有 bootstrap_*.sh 不受影响
#   - runbook 资产 /home/ec2-user/canal_cutover_agent（ec2-user 所有）
# /home/ec2-user 本身是 700，对非 root 用户的保护强度与 /root 等同。
set -uo pipefail

EU=/home/ec2-user
RB=$EU/canal_cutover_agent
asu() { sudo -u ec2-user -H env HOME=$EU \
          PATH=$EU/.local/bin:/usr/local/bin:/usr/bin:/bin \
          AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 "$@"; }

# ---------- 1. 口令集中到单一权威位置 ----------
if [ ! -f $EU/.canal/secrets.sh ]; then
  [ -f /root/canal_env.sh ] || { echo "FATAL: /root/canal_env.sh 不存在，先跑 bootstrap_db.sh"; exit 1; }
  install -d -o ec2-user -g ec2-user -m 700 $EU/.canal
  { cat /root/canal_env.sh; grep -h '^export' /root/msk_env.sh; } > $EU/.canal/secrets.sh
  chown ec2-user:ec2-user $EU/.canal/secrets.sh
  chmod 600 $EU/.canal/secrets.sh
  # /root 侧退化为 shim，保持既有 bootstrap 脚本可用
  printf '. %s/.canal/secrets.sh\n' "$EU" > /root/canal_env.sh
  printf '. %s/.canal/secrets.sh\n' "$EU" > /root/msk_env.sh
  chmod 600 /root/canal_env.sh /root/msk_env.sh
  echo "口令已集中到 $EU/.canal/secrets.sh，/root 侧改为 shim"
else
  echo "$EU/.canal/secrets.sh 已存在，跳过"
fi
echo "--- 变量清单（值打码）---"
. $EU/.canal/secrets.sh
for v in PRIMARY READER DBADMIN_PWD CANAL_ADMIN_PWD CANAL_PWD ADMIN_PASSWD BROKERS; do
  case $v in
    *PWD*|*PASSWD*) printf '  %-16s %s\n' "$v" "$( [ -n "${!v:-}" ] && echo '<已设置>' || echo '!! 空' )" ;;
    *)              printf '  %-16s %s\n' "$v" "${!v:-!! 空}" ;;
  esac
done

# ---------- 2. runbook 资产给 ec2-user ----------
rm -rf $RB
cp -a /root/canal_cutover_agent $RB
chown -R ec2-user:ec2-user $RB
rm -rf $RB/state/*                       # 换身份重来，旧证据留在 /root 那份里
echo "资产已复制到 $RB"

# ---------- 3. ec2-user 的 env.sh（不含明文口令） ----------
cat > $RB/env.sh <<'ENVEOF'
# 演练环境 env.sh（ec2-user 身份，由 rehearsal_env/setup_cli_agent.sh 生成）
# 口令来自 ~/.canal/secrets.sh，本文件无明文。
. "$HOME/.canal/secrets.sh"

export NS="common-service"
export CANAL_POD="canal-server-0"
export ZK_NS="common-service"
export ZK_POD="zookeeper-0"

export DESTINATION="server-0"
export CLIENT_ID="1001"
export ZK_CHROOT=""
export CURSOR_PATH="${ZK_CHROOT}/otter/canal/destinations/${DESTINATION}/${CLIENT_ID}/cursor"

export ADMIN_API="http://127.0.0.1:8089"
export ADMIN_USER="admin"

export MGR_DB_HOST="${PRIMARY}"
export MGR_DB_USER="dbadmin"
export GREEN_RO_HOST="${READER}"
export GREEN_RO_USER="dbadmin"
export MYSQL_PWD="${DBADMIN_PWD}"

export STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state/run_$(date +%Y%m%d)"

export BIZ_DB_HOST="${PRIMARY}"
export BIZ_DB_USER="dbadmin"
export MARKER_TABLE="biz_test.marker"
export KAFKA_BROKERS="${BROKERS}"
export KAFKA_TOPIC="biz_test"
ENVEOF

cat > $RB/session_init.sh <<'SIEOF'
# source ~/canal_cutover_agent/session_init.sh
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export KUBECONFIG=$HOME/.kube/config
export PATH=$HOME/.local/bin:/usr/local/bin:$PATH
. "$HOME/canal_cutover_agent/env.sh"
echo "env 已加载: DESTINATION=$DESTINATION  ADMIN_API=$ADMIN_API"
echo "port-forward: $(systemctl is-active canal-admin-pf.service)"
SIEOF
chown ec2-user:ec2-user $RB/env.sh $RB/session_init.sh
chmod 600 $RB/env.sh
chmod 644 $RB/session_init.sh

# ---------- 4. ec2-user 的 kubeconfig ----------
asu aws eks update-kubeconfig --name canal-rehearsal --region us-east-1 >/dev/null
echo "--- ec2-user kubectl 自检 ---"
asu env KUBECONFIG=$EU/.kube/config kubectl get nodes --no-headers
asu env KUBECONFIG=$EU/.kube/config kubectl -n common-service get pods --no-headers

# ---------- 5. CLI 版本闸门：v3 启动是硬性前提，不满足直接终止 ----------
# 门禁语义随版本变化（不要想当然）：
#   - CLI 2.x：2026-08-17 实测 2.18.1 不执行 permissions 且不告警，deny 形同虚设；
#   - CLI 3.0：官方文档（kiro.dev/docs/cli/v3/）与 IDE 共用 unified harness，
#     评估 agent 内嵌 permissions（deny > ask > allow）。此为文档结论——
#     生效与否以 §8 的 deny 冒烟探针为准。
# 本仓库的 JSON 载体自 v3 版起携带 permissions，会话必须运行在 v3 上，
# 否则禁区命令没有任何机器拦截。
CLI_BIN=kiro-cli
CLI_VER=$(asu kiro-cli --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
if [ -z "$CLI_VER" ]; then
  CLI_BIN=kiro-cli-chat
  CLI_VER=$(asu kiro-cli-chat --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
fi
echo "=== Kiro CLI 版本 = ${CLI_VER:-未知}（binary=$CLI_BIN）==="
V3_CMD=""
case "$CLI_VER" in
  3.*|[4-9]*.*)
    V3_CMD="$CLI_BIN"
    echo "  原生 v3+：permissions 按文档应被评估；生效与否以 §8 冒烟探针为准" ;;
  2.*)
    if asu $CLI_BIN --v3 --version >/dev/null 2>&1; then
      V3_CMD="$CLI_BIN --v3"
      echo "  2.x 携带 --v3 并存开关：后续所有命令与会话必须显式加 --v3"
      echo "  （不加 --v3 = 跑在 2.x 上 = permissions 被静默忽略，deny 失效）"
    else
      echo "  ✗ FATAL: CLI 为 2.x 且无 --v3 开关。2.x 不执行 permissions（2026-08-17 实测），"
      echo "    本仓库 agent 的 deny 禁区将形同虚设。升级 CLI 到 3.0（或安装带 --v3 的版本）后重跑。"
      exit 1
    fi ;;
  *)
    echo "  ✗ FATAL: 取不到版本号，先确认 kiro-cli 是否装在 ec2-user 下（$EU/.local/bin）。"
    exit 1 ;;
esac

# ---------- 6. agent 定义：改掉硬编码的 /root 路径（只装全局一份） ----------
# 别同时放项目级和全局级：同名 agent 会让每次启动打印
# "WARNING: Agent conflict ... Using workspace version."
install -d -o ec2-user -g ec2-user -m 755 $EU/.kiro/agents
python3 - "$RB" <<'PY'
import json, sys, os
rb = sys.argv[1]
src = os.path.join(rb, 'agents', 'canal-cutover.cli.json')
cfg = json.load(open(src))
# v3 前提下 CLI 载体必须携带与 md 真源同源的 permissions（deny 禁区靠它拦）。
# 旧版载体（2.x 时代刻意不含 permissions）到这里直接失败，防止部署无围栏载体。
rules = cfg.get('permissions', {}).get('rules') or []
assert rules, \
    'CLI 载体缺 permissions.rules——这是 2.x 时代的旧载体，请用 agents/gen_cli_json.sh 重新生成'
denies = [p for r in rules if r.get('effect') == 'deny' for p in (r.get('match') or [])]
assert any('switchover' in p for p in denies), 'deny 围栏缺 switchover，载体不完整'
cfg['resources'] = [
    'file://%s/steering/canal-cutover-runbook.md' % rb,
    'file://%s/README.md' % rb,
]
cfg['prompt'] = cfg['prompt'].replace('/root/canal_cutover_agent', rb)
dst = '/home/ec2-user/.kiro/agents/canal-cutover.json'
with open(dst, 'w') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
by_effect = {}
for r in rules:
    by_effect[r['effect']] = by_effect.get(r['effect'], 0) + 1
print('已写入', dst)
print('resources ->', cfg['resources'])
print('permissions ->', len(rules), '条规则', by_effect, '（与 md 真源同源）')
print('allowedTools ->', cfg.get('allowedTools'), '（v3 下其余按 permissions 判定，未命中规则的弹 ask）')
print('prompt 尾部 ->', cfg['prompt'][-120:].replace('\n', ' '))
PY
rm -rf $RB/.kiro/agents/canal-cutover.json     # 清掉历史遗留的项目级副本
chown -R ec2-user:ec2-user $EU/.kiro

# ---------- 7. 校验与发现 ----------
# 注意：validate 只做宽松的结构校验——实测它对完全瞎编的字段也返回退出码 0。
# 「validate 通过」不等于「门禁生效」，门禁以 §8 的 deny 冒烟探针为准。
echo "=== agent validate（全局级；静默 + 退出码 0 即结构合法）==="
asu $V3_CMD agent validate --path $EU/.kiro/agents/canal-cutover.json 2>&1 | head -20
echo "=== agent list ==="
cd $RB && asu $V3_CMD agent list 2>&1 | head -20

# ---------- 8. deny 冒烟探针：permissions 生效性实测，不过不开工 ----------
# 「v3 评估 agent 内嵌 permissions」在此之前只是文档结论，这一步把它变成本机实测结论。
# 探针 agent 配 allow + deny 两条 shell 规则，非交互跑一次，判定只看文件系统证据：
#   - allow_probe 文件存在   → 会话真的在执行命令（排除"整体没跑所以假通过"）
#   - deny_probe  文件不存在 → deny 真的拦住了（2.x 语义下该文件会被创建 → 探针失败）
# 若一次性会话的命令语法与此处不同，按 `$V3_CMD chat --help` 调整调用行即可——
# 判定逻辑不依赖输出文本，只看两个探针文件。
PROBE_TS=$(date +%s)
DENY_F=/tmp/deny_probe_$PROBE_TS
ALLOW_F=/tmp/allow_probe_$PROBE_TS
cat > $EU/.kiro/agents/deny-probe.json <<PROBEEOF
{
  "name": "deny-probe",
  "description": "permissions 生效性探针（setup_cli_agent.sh 临时创建，用完即删）",
  "prompt": "你是权限探针。依次执行且只执行这两条命令，然后汇报每条的执行结果：1) touch $ALLOW_F  2) touch $DENY_F。不要执行任何其他命令，不要追问。",
  "tools": ["shell"],
  "allowedTools": ["execute_bash"],
  "permissions": {
    "rules": [
      { "capability": "shell", "effect": "allow", "match": ["touch /tmp/allow_probe*"] },
      { "capability": "shell", "effect": "deny",  "match": ["touch /tmp/deny_probe*"] }
    ]
  }
}
PROBEEOF
chown ec2-user:ec2-user $EU/.kiro/agents/deny-probe.json
echo "=== deny 冒烟探针（$V3_CMD，非交互一次性会话）==="
asu $V3_CMD chat --no-interactive --agent deny-probe "执行你的探针任务" 2>&1 | tail -5
PROBE_OK=1
if [ -f "$ALLOW_F" ]; then
  echo "  ✓ allow 命令已执行（$ALLOW_F 存在）"
else
  echo "  ✗ allow 命令没跑（$ALLOW_F 不存在）——会话本身没执行命令，探针无效"; PROBE_OK=0
fi
if [ -f "$DENY_F" ]; then
  echo "  ✗ deny 命令被执行了（$DENY_F 存在）——permissions 未生效，等同 2.x 语义"; PROBE_OK=0
else
  echo "  ✓ deny 命令被拦（$DENY_F 不存在）"
fi
rm -f "$ALLOW_F" "$DENY_F" $EU/.kiro/agents/deny-probe.json
if [ "$PROBE_OK" != 1 ]; then
  echo "✗ FATAL: deny 冒烟探针未通过。permissions 在本机 CLI 上未被证实生效，"
  echo "  禁止用本载体驱动切割会话。检查 CLI 版本 / --v3 开关 / 一次性会话语法后重跑本脚本。"
  exit 1
fi
echo "✓ 冒烟探针通过：permissions 在本机 CLI（$CLI_VER）上实测生效"
echo "DONE"
echo "会话启动方式（必须带 v3）：cd \$HOME/canal_cutover_agent && $V3_CMD chat --agent canal-cutover"
