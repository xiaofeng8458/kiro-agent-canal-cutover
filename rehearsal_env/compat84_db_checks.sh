#!/usr/bin/env bash
# 跳板机执行：8.4 兼容性预检 第 1、2 项（认证方式 / 语法适配）。只读为主，写仅限临时测试库。
# 前置：canal-compat84-tmp 已 available，跳板机可读其 managed master secret。
set -uo pipefail
. /home/ec2-user/.canal/secrets.sh 2>/dev/null || true

H84=$(aws rds describe-db-instances --db-instance-identifier canal-compat84-tmp --region us-east-1 \
        --query 'DBInstances[0].Endpoint.Address' --output text)
SARN=$(aws rds describe-db-instances --db-instance-identifier canal-compat84-tmp --region us-east-1 \
        --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
PW84=$(aws secretsmanager get-secret-value --secret-id "$SARN" --region us-east-1 \
        --query SecretString --output text | jq -r .password)
[ -n "$PW84" ] || { echo "取 8.4 master 口令失败"; exit 1; }
echo "8.4 endpoint: $H84"

# 口令落到 ec2-user 的 secrets（供第 3 项的 pod 配置使用），不回传本地
CANAL84_PWD=$(grep -oP "(?<=^export CANAL84_PWD=')[^']*" /home/ec2-user/.canal/secrets.sh 2>/dev/null || true)
if [ -z "$CANAL84_PWD" ]; then
  CANAL84_PWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  printf "export CANAL84_PWD='%s'\n" "$CANAL84_PWD" >> /home/ec2-user/.canal/secrets.sh
fi
printf "export H84='%s'\n" "$H84" >> /home/ec2-user/.canal/secrets.sh
chown ec2-user:ec2-user /home/ec2-user/.canal/secrets.sh; chmod 600 /home/ec2-user/.canal/secrets.sh

export MYSQL_PWD="$PW84"
m() { mysql -h "$H84" -u dbadmin "$@"; }

echo
echo "############ 环境底座确认 ############"
m -N -e "SELECT @@version, @@version_comment, @@gtid_mode, @@enforce_gtid_consistency, @@binlog_format, @@log_bin;"
echo "--- 默认认证插件策略 ---"
m -N -e "SELECT @@authentication_policy;"
echo "--- mysql_native_password 插件是否装载 ---"
m -e "SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE FROM information_schema.plugins WHERE PLUGIN_NAME LIKE '%password%';"

echo
echo "############ 第 1 项：认证方式 ############"
m -e "CREATE DATABASE IF NOT EXISTS compat_test DEFAULT CHARACTER SET utf8mb4;
      CREATE TABLE IF NOT EXISTS compat_test.marker(
        id BIGINT AUTO_INCREMENT PRIMARY KEY, tag VARCHAR(64) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" 2>&1

echo "--- 1a. 能否在 8.4 上创建 mysql_native_password 账号 ---"
if m -e "CREATE USER IF NOT EXISTS 'canal'@'%' IDENTIFIED WITH mysql_native_password BY '${CANAL84_PWD}';
         ALTER USER 'canal'@'%' IDENTIFIED WITH mysql_native_password BY '${CANAL84_PWD}';
         GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'canal'@'%';" 2>&1; then
  echo "结论 1a: 可以创建 native 账号"
else
  echo "结论 1a: !! 无法创建 native 账号"
fi

echo "--- 1b. 对照组：caching_sha2_password 账号 ---"
m -e "CREATE USER IF NOT EXISTS 'canal_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY '${CANAL84_PWD}';
      ALTER USER 'canal_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY '${CANAL84_PWD}';
      GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'canal_sha2'@'%';" 2>&1

m -e "SELECT user, host, plugin FROM mysql.user WHERE user IN ('canal','canal_sha2','dbadmin');"

echo "--- 1c. canal（native）实际连接 ---"
if MYSQL_PWD="$CANAL84_PWD" mysql -h "$H84" -u canal -N -e "SELECT 'native 认证成功' AS r;" 2>&1; then
  echo "结论 1c: native 账号可在 8.4 认证 ✅"
else
  echo "结论 1c: !! native 账号在 8.4 认证失败 ❌"
fi

echo
echo "############ 第 2 项：语法适配（canal 1.1.8 寻位依赖）############"
for stmt in "SHOW MASTER STATUS" "SHOW BINARY LOG STATUS" "SHOW BINARY LOGS" \
            "SHOW SLAVE STATUS" "SHOW REPLICA STATUS" "SHOW GLOBAL VARIABLES LIKE 'server_uuid'"; do
  printf '%-42s ' "$stmt"
  out=$(MYSQL_PWD="$CANAL84_PWD" mysql -h "$H84" -u canal -N -e "$stmt" 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "❌ 失败: $(echo "$out" | head -1 | cut -c1-110)"
  else
    echo "✅ 可用: $(echo "$out" | head -1 | cut -c1-80)"
  fi
done

echo
echo "--- 造几行 binlog 事件供第 3 项解析 ---"
m -e "INSERT INTO compat_test.marker(tag) VALUES ('c84-1'),('c84-2'),('c84-3');"
m -N -e "SELECT CONCAT('compat_test.marker 行数=', COUNT(*)) FROM compat_test.marker;"
m -e "SHOW BINARY LOG STATUS;" 2>&1 | head -3
echo "DONE"
