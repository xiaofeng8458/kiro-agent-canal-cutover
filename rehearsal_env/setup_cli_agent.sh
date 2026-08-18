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

# ---------- 5. CLI 版本闸门：门禁语义随版本变化，必须先确认 ----------
# 2026-08-17 实测（本地 Kiro CLI 2.18.1）：CLI 2.x 不认 Markdown 定义，也不执行
# frontmatter 里的 permissions 规则且不告警。故 CLI 侧只用 JSON 载体，门禁靠
# allowedTools（仅 fs_read 免批）+ 脚本 YES + 契约。换版本前先重测这三条再改配置。
CLI_VER=$(asu kiro-cli-chat --version 2>/dev/null | awk '{print $NF}')
echo "=== Kiro CLI 版本 = ${CLI_VER:-未知} ==="
case "$CLI_VER" in
  2.18.*) echo "  与本仓库验证过的版本一致，按 JSON 载体 + allowedTools 门禁部署" ;;
  2.*)    echo "  ⚠️  2.x 但非 2.18.x：门禁机制大概率相同，仍建议重跑一遍冒烟" ;;
  "")     echo "  ⚠️  取不到版本号，先确认 kiro-cli 是否装在 ec2-user 下" ;;
  *)      echo "  ⚠️  非 2.x！CLI 3.0 起权限模型改为声明式 permissions，本 JSON 载体的"
          echo "      allowedTools 语义可能已变。部署前必须实测：deny 规则是否真的拦得住、"
          echo "      Markdown 载体是否可直接用。不要假设更严格。" ;;
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
assert 'permissions' not in cfg, \
    'CLI 载体不应含 permissions（CLI 2.x 会静默忽略）——请用 agents/gen_cli_json.sh 重新生成'
cfg['resources'] = [
    'file://%s/steering/canal-cutover-runbook.md' % rb,
    'file://%s/README.md' % rb,
]
cfg['prompt'] = cfg['prompt'].replace('/root/canal_cutover_agent', rb)
dst = '/home/ec2-user/.kiro/agents/canal-cutover.json'
with open(dst, 'w') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
print('已写入', dst)
print('resources ->', cfg['resources'])
print('allowedTools ->', cfg.get('allowedTools'), '（其余工具逐条 y/t 确认）')
print('prompt 尾部 ->', cfg['prompt'][-120:].replace('\n', ' '))
PY
rm -rf $RB/.kiro/agents/canal-cutover.json     # 清掉历史遗留的项目级副本
chown -R ec2-user:ec2-user $EU/.kiro

# ---------- 7. 校验与发现 ----------
# 注意：validate 只做宽松的结构校验——实测它对完全瞎编的字段也返回退出码 0。
# 「validate 通过」不等于「门禁生效」，门禁要靠 §8 的冒烟和会话里的实际弹窗确认。
echo "=== agent validate（全局级；静默 + 退出码 0 即结构合法）==="
asu kiro-cli-chat agent validate --path $EU/.kiro/agents/canal-cutover.json 2>&1 | head -20
echo "=== agent list ==="
cd $RB && asu kiro-cli-chat agent list 2>&1 | head -20
echo "DONE"
