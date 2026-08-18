#!/usr/bin/env bash
# 在跳板机上执行（经 ssm_run.sh -f 送入）：初始化演练环境数据库。
# 密码在跳板机本地生成并只落 /root/canal_env.sh(600)，不回传本地、不进日志。
set -uo pipefail

# 环境标识由 ssm_run.sh 从本地透传（本地先 `source ./stack_outputs.sh`）。
# 仓库内不硬编码 endpoint / secret 名。
PRIMARY="${PRIMARY_ENDPOINT:?缺少 PRIMARY_ENDPOINT（本地先 source ./stack_outputs.sh）}"
READER="${READER_ENDPOINT:?缺少 READER_ENDPOINT（本地先 source ./stack_outputs.sh）}"
SECRET="${DB_SECRET_NAME:?缺少 DB_SECRET_NAME（本地先 source ./stack_outputs.sh）}"

if [ -f /root/canal_env.sh ]; then
  echo "/root/canal_env.sh 已存在，复用既有密码"
  . /root/canal_env.sh
else
  DBADMIN_PWD=$(aws secretsmanager get-secret-value --secret-id "$SECRET" \
    --query SecretString --output text | jq -r .password)
  [ -n "$DBADMIN_PWD" ] || { echo "取 dbadmin 密码失败"; exit 1; }
  # 只用字母数字，避开 shell/properties/JDBC 的转义坑
  CANAL_ADMIN_PWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  CANAL_PWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  umask 077
  cat > /root/canal_env.sh <<EOF
export PRIMARY='$PRIMARY'
export READER='$READER'
export DBADMIN_PWD='$DBADMIN_PWD'
export CANAL_ADMIN_PWD='$CANAL_ADMIN_PWD'
export CANAL_PWD='$CANAL_PWD'
EOF
  chmod 600 /root/canal_env.sh
  . /root/canal_env.sh
  echo "已生成 /root/canal_env.sh (600)"
fi

export MYSQL_PWD="$DBADMIN_PWD"

# canal 复制账号用 mysql_native_password：canal 1.1.8 + caching_sha2 实测 parser 必崩
# （见 rehearsal_env/README.md「重大发现」，alibaba/canal#5403）。canal_admin 走 caching_sha2 无此问题。
mysql -h "$PRIMARY" -u dbadmin <<SQL
CREATE DATABASE IF NOT EXISTS canal_manager DEFAULT CHARACTER SET utf8mb4;

CREATE USER IF NOT EXISTS 'canal_admin'@'%' IDENTIFIED WITH caching_sha2_password BY '${CANAL_ADMIN_PWD}';
ALTER USER 'canal_admin'@'%' IDENTIFIED WITH caching_sha2_password BY '${CANAL_ADMIN_PWD}';
GRANT ALL ON canal_manager.* TO 'canal_admin'@'%';

CREATE USER IF NOT EXISTS 'canal'@'%' IDENTIFIED WITH mysql_native_password BY '${CANAL_PWD}';
ALTER USER 'canal'@'%' IDENTIFIED WITH mysql_native_password BY '${CANAL_PWD}';
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'canal'@'%';
FLUSH PRIVILEGES;

CREATE DATABASE IF NOT EXISTS biz_test DEFAULT CHARACTER SET utf8mb4;
CREATE TABLE IF NOT EXISTS biz_test.marker (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  tag VARCHAR(64) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQL
rc=$?
[ $rc -eq 0 ] || { echo "初始化 SQL 失败 rc=$rc"; exit $rc; }

mysql -h "$PRIMARY" -u dbadmin -e "CALL mysql.rds_set_configuration('binlog retention hours', 168);"
echo "=== binlog 保留配置 ==="
mysql -h "$PRIMARY" -u dbadmin -e "CALL mysql.rds_show_configuration;"

echo "=== GTID / binlog 关键参数（primary）==="
mysql -h "$PRIMARY" -u dbadmin -N -e "SELECT @@hostname, @@gtid_mode, @@enforce_gtid_consistency, @@binlog_format, @@log_bin, @@version;"
echo "=== GTID / binlog 关键参数（reader，canal 的订阅点）==="
mysql -h "$READER" -u dbadmin -N -e "SELECT @@hostname, @@gtid_mode, @@enforce_gtid_consistency, @@binlog_format, @@log_bin, @@version;"

echo "=== 账号认证插件 ==="
mysql -h "$PRIMARY" -u dbadmin -N -e "SELECT user, host, plugin FROM mysql.user WHERE user IN ('canal','canal_admin','dbadmin');"

echo "=== canal 账号连 reader 自检（应返回 1）==="
MYSQL_PWD="$CANAL_PWD" mysql -h "$READER" -u canal -N -e "SELECT 1;"
echo "=== reader binlog 位点可见性 ==="
MYSQL_PWD="$CANAL_PWD" mysql -h "$READER" -u canal -e "SHOW MASTER STATUS;" 2>&1 | head -5
echo "DONE"
