#!/usr/bin/env bash
# 本地执行：把 canal_cutover_agent 资产打包送到跳板机 /root/canal_cutover_agent，
# 并按本次演练环境生成 env.sh 与 session_init.sh，最后跑 P0 断言验收。
set -euo pipefail
cd "$(dirname "$0")/.."          # canal_cutover_agent/
HERE="$(pwd)"

tar czf /tmp/agent_assets.tgz --exclude='.git' --exclude='rehearsal_env' \
  --exclude='node_modules' --exclude='state' --exclude='reports' --exclude='env.sh' .
B64=$(base64 < /tmp/agent_assets.tgz | tr -d '\n')

cat > /tmp/deploy_assets_remote.sh <<REMOTE
set -uo pipefail
. /root/canal_env.sh
. /root/msk_env.sh

rm -rf /root/canal_cutover_agent
mkdir -p /root/canal_cutover_agent
cd /root/canal_cutover_agent
echo "$B64" | base64 -d | tar xzf -
find . -name '._*' -delete
chmod +x scripts/*.sh
echo "=== 资产清单 ==="
ls scripts/ steering/ agents/

# ---- env.sh：本次演练环境参数（密码不写死，统一从 /root/canal_env.sh 取）----
umask 077
cat > env.sh <<'ENVEOF'
# 演练环境 env.sh（由 rehearsal_env/deploy_agent_assets.sh 生成）
# 密码统一来自 /root/canal_env.sh，本文件不含明文口令。
. /root/canal_env.sh
. /root/msk_env.sh

# --- Kubernetes ---
export NS="common-service"
export CANAL_POD="canal-server-0"
export ZK_NS="common-service"
export ZK_POD="zookeeper-0"

# --- Canal ---
export DESTINATION="server-0"
export CLIENT_ID="1001"
export ZK_CHROOT=""
export CURSOR_PATH="\${ZK_CHROOT}/otter/canal/destinations/\${DESTINATION}/\${CLIENT_ID}/cursor"

# --- Canal Admin（经 systemd 托管的 port-forward canal-admin-pf.service）---
export ADMIN_API="http://127.0.0.1:8089"
export ADMIN_USER="admin"
export ADMIN_PASSWD="\${ADMIN_PASSWD}"

# --- 数据库 ---
export MGR_DB_HOST="\${PRIMARY}"
export MGR_DB_USER="dbadmin"
export GREEN_RO_HOST="\${READER}"
export GREEN_RO_USER="dbadmin"
export MYSQL_PWD="\${DBADMIN_PWD}"

# --- 运行 ---
export STATE_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/state/run_\$(date +%Y%m%d)"

# --- 造数与端到端验证 ---
export BIZ_DB_HOST="\${PRIMARY}"
export BIZ_DB_USER="dbadmin"
export MARKER_TABLE="biz_test.marker"
export KAFKA_BROKERS="\${BROKERS}"
export KAFKA_TOPIC="biz_test"
ENVEOF
chmod 600 env.sh

# ---- session_init.sh：每次登录 source 一次 ----
cat > session_init.sh <<'SIEOF'
# source /root/canal_cutover_agent/session_init.sh
export HOME=/root
export KUBECONFIG=/root/.kube/config
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export PATH=/usr/local/bin:/root/kirocli/bin:$PATH
. /root/canal_cutover_agent/env.sh
echo "env 已加载: DESTINATION=\$DESTINATION  ADMIN_API=\$ADMIN_API"
echo "port-forward: \$(systemctl is-active canal-admin-pf.service)"
SIEOF
chmod 644 session_init.sh

echo "=== env.sh 自检（口令打码）==="
. ./env.sh
for v in NS CANAL_POD ZK_NS ZK_POD DESTINATION CLIENT_ID CURSOR_PATH ADMIN_API MGR_DB_HOST GREEN_RO_HOST MARKER_TABLE KAFKA_TOPIC KAFKA_BROKERS STATE_DIR; do
  printf '%-14s = %s\n' "\$v" "\${!v}"
done
printf '%-14s = %s\n' ADMIN_PASSWD "\$( [ -n "\$ADMIN_PASSWD" ] && echo '<已设置>' || echo '!! 空' )"
printf '%-14s = %s\n' MYSQL_PWD    "\$( [ -n "\$MYSQL_PWD" ] && echo '<已设置>' || echo '!! 空' )"
echo "REMOTE_DONE"
REMOTE

"$HERE/rehearsal_env/ssm_run.sh" -f /tmp/deploy_assets_remote.sh
