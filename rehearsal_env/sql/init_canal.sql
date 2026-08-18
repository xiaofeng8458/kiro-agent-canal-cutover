-- 在 RDS primary 上以 dbadmin 执行（凭证在 Secrets Manager，见 stack 输出 DbSecretName）
-- 注意：两处密码占位符必须替换为强密码后再执行
--
-- ⚠️ 本文件是**手工兜底路径**，且刻意保留了"canal 账号用 caching_sha2_password"的原始写法，
--    作为升级前建议的记录。它与实测结论冲突：canal 1.1.8 + caching_sha2 在 RDS MySQL 8.0.42
--    上报文解析必崩（alibaba/canal#5403）。
--    **推荐用 `bootstrap_db.sh`**，那里 canal 复制账号建成 mysql_native_password，
--    是唯一在 8.0.42 与 8.4.10 上都实测可用的选项。详见 rehearsal_env/README.md。

-- 1. canal-admin 元数据库（表结构由官方 canal_manager.sql 导入，见 README 第 5 步）
CREATE DATABASE IF NOT EXISTS canal_manager DEFAULT CHARACTER SET utf8mb4;

-- 2. canal-admin 连接账号
CREATE USER 'canal_admin'@'%' IDENTIFIED WITH caching_sha2_password BY '<REPLACE_STRONG_PASSWORD_1>';
GRANT ALL ON canal_manager.* TO 'canal_admin'@'%';

-- 3. canal 复制账号
--    与生产一致使用 caching_sha2_password，提前规避 8.4 移除 mysql_native_password 的问题
CREATE USER 'canal'@'%' IDENTIFIED WITH caching_sha2_password BY '<REPLACE_STRONG_PASSWORD_2>';
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'canal'@'%';

-- 4. 业务测试库（造数端写这里）
CREATE DATABASE IF NOT EXISTS biz_test DEFAULT CHARACTER SET utf8mb4;
CREATE TABLE IF NOT EXISTS biz_test.marker (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  tag VARCHAR(64) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 5. binlog 保留窗口（保护 1236 故障处置窗口内的业务 binlog，RDS for MySQL 上限 168h）
CALL mysql.rds_set_configuration('binlog retention hours', 168);
CALL mysql.rds_show_configuration;
