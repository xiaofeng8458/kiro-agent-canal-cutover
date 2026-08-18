# 跳板机环境配置清单（Bastion Host）

演练环境运维操作点的完整配置档案。实例随 CDK 栈管理，本文记录栈内定义 + 部署后配置。
（2026-07-24 初版；**2026-08-15 环境重建后更新**，基于实际运行状态）

## 1. 基础设施（CDK 管理，lib/rehearsal-stack.ts）

> 本文中的实例 ID / VPC ID / endpoint / Secret 名等一律是**示例占位符**，
> 实际值以你本次部署的栈 Outputs 为准（`source rehearsal_env/stack_outputs.sh`）。

| 项 | 值 | 备注 |
|---|---|---|
| 实例 ID | `i-0123456789abcdef0`（示例） | 每次替换都会变，**以栈 Outputs 的 BastionId 为准** |
| 规格 | **t3.medium**（4GB） | 原 t3.micro 实证被 Kiro CLI 会话 OOM 压宕（2026-07-23），已升配 |
| AMI | Amazon Linux 2023，x86_64 | |
| 磁盘 | 10GB gp3，加密，随实例删除 | |
| 子网 | private（canal-cutover-subnet-private*） | 原 public 方案因子网未开自动分配公网 IP 导致 SSM 注册失败，改私有子网走 NAT |
| 安全组 | BastionSg：**零 inbound**，egress 全放 | 无 SSH 密钥，仅 SSM 接入 |
| IMDS | IMDSv2 强制 | |
| VPC | vpc-0123456789abcdef0（us-east-1） | |

## 2. IAM 权限（BastionRole）

- `AmazonSSMManagedInstanceCore`（SSM 接入）
- Secrets Manager：读 DB 凭证（CanalRehearsalStackPrimaryS-*）
- `kafka:GetBootstrapBrokers` / `kafka:DescribeCluster`（限本 MSK 集群）
- `eks:DescribeCluster`（update-kubeconfig 所需）
- EKS aws-auth：masters 映射（kubectl 完整权限，由 CDK `awsAuth.addMastersRole` 写入）

## 3. 已安装软件

| 软件 | 来源 | 位置 |
|---|---|---|
| mysql 客户端（mariadb105）、jq、git | userData 自动安装 | 系统路径 |
| kubectl v1.35.0 | userData 下载 | /usr/local/bin/kubectl |
| **Kiro CLI 2.18.1** | 手工安装（2026-08-15） | **/home/ec2-user/.local/bin/**（kiro-cli / kiro-cli-chat / kiro-cli-term） |
| kubeconfig | `aws eks update-kubeconfig --name canal-rehearsal` | /root/.kube/config **与** /home/ec2-user/.kube/config |

Kiro CLI 登录态：`/home/ec2-user/.kiro/`（IAM Identity Center，`kiro-cli whoami` 可验）。

## 4. 运维身份与目录布局

⚠️ **2026-08-15 起 runbook 的操作身份是 `ec2-user`，不是 root。**

原因：Kiro CLI 装在 ec2-user 下、登录态也在 ec2-user 的 `~/.kiro`，agent 会话必然以
ec2-user 运行；而首轮 bootstrap 把资产和口令放在 `/root`（600），ec2-user 读不到。
因此把 runbook 操作身份统一到 ec2-user，口令收敛到**单一权威位置**，`/root` 侧留 shim
保证既有 `bootstrap_*.sh`（以 root 跑）不受影响。

`/home/ec2-user` 本身是 `drwx------`，对非 root 用户的保护强度与 `/root` 等同；
ec2-user 另有 NOPASSWD sudo，故这不构成权限降级。

```
/home/ec2-user/                       # 700，runbook 操作身份
├── .canal/secrets.sh                 # ★ 口令唯一权威位置（600, ec2-user）
│                                     #   PRIMARY/READER/DBADMIN_PWD/CANAL_ADMIN_PWD/
│                                     #   CANAL_PWD/ADMIN_PASSWD/BROKERS
├── .kiro/
│   ├── settings/cli.json
│   └── agents/canal-cutover.json     # ★ CLI agent（只放全局一份，见第 9 节坑 #8）
├── .kube/config                      # ec2-user 自己的 kubeconfig
├── .local/bin/                       # Kiro CLI 可执行
└── canal_cutover_agent/              # runbook 资产（ec2-user 所有）
    ├── scripts/                      # 00-51 号脚本 + lib/common.sh
    ├── steering/canal-cutover-runbook.md
    ├── agents/                       # 定义源件（md=唯一真源，cli.json=CLI 实际加载的载体）
    ├── state/run_YYYYMMDD/           # 证据流水、cursor 存档、并集、对账产物
    ├── env.sh                        # 环境参数（600，source ~/.canal/secrets.sh，无明文）
    └── session_init.sh               # 会话初始化

/root/
├── canal_env.sh, msk_env.sh          # shim：仅 `. /home/ec2-user/.canal/secrets.sh`
├── canal_cutover_agent/              # 首轮部署的副本（root 身份兜底，含首轮 state 证据）
├── .kube/config
└── work/                             # bootstrap 过程产物（k8s manifests、properties 模板）
```

## 5. env.sh 变量清单

```
NS=common-service                CANAL_POD=canal-server-0
ZK_NS=common-service             ZK_POD=zookeeper-0
DESTINATION=server-0             CLIENT_ID=1001        ZK_CHROOT=""
CURSOR_PATH=/otter/canal/destinations/server-0/1001/cursor
ADMIN_API=http://127.0.0.1:8089  ADMIN_USER=admin      ADMIN_PASSWD=<取自 ~/.canal/secrets.sh>
MGR_DB_HOST=<PrimaryEndpoint>    MGR_DB_USER=dbadmin
GREEN_RO_HOST=<ReaderEndpoint>   GREEN_RO_USER=dbadmin
MARKER_TABLE=biz_test.marker     KAFKA_TOPIC=biz_test
KAFKA_BROKERS=<MSK bootstrap 双 broker:9092，取自 ~/.canal/secrets.sh 的 BROKERS>
STATE_DIR=state/run_$(date +%Y%m%d)
MYSQL_PWD=<取自 ~/.canal/secrets.sh 的 DBADMIN_PWD>
```

ec2-user 那份 env.sh 由 `rehearsal_env/setup_cli_agent.sh` 生成，开头只
source `~/.canal/secrets.sh`，因此**文件内无任何明文口令**。
（root 那份由 `deploy_agent_assets.sh` 生成，走 `/root/canal_env.sh` shim，等效。）

取值形态示例（**下表全是占位符**，实际值以本次部署的栈 Outputs 为准：
本地 `source rehearsal_env/stack_outputs.sh` 即可导出）：

| 变量 | 值 |
|---|---|
| MGR_DB_HOST | canalrehearsalstack-primary-example.abcdefghijkl.us-east-1.rds.amazonaws.com |
| GREEN_RO_HOST | canalrehearsalstack-reader-example.abcdefghijkl.us-east-1.rds.amazonaws.com |
| KAFKA_BROKERS | b-1.canalrehearsal.abc123.c2.kafka.us-east-1.amazonaws.com:9092,b-2.canalrehearsal.abc123.c2.kafka.us-east-1.amazonaws.com:9092 |
| DbSecretName | CanalRehearsalStackPrimaryS-EXAMPLE |
| clusterId / instanceId | 1 / 1（Admin 内） |

## 6. 常驻进程

| 进程 | 启动方式 | 重启自启 | 日志 |
|---|---|---|---|
| kubectl port-forward svc/canal-admin 8089 | **systemd `canal-admin-pf.service`**（enabled+active） | ✅ 是 | `journalctl -u canal-admin-pf` |
| 造数端 | `scripts/40_loadgen.sh start`（pid 在 state/run_*/loadgen.pid） | ❌ 否 | state/run_*/loadgen.err |

port-forward 于 2026-08-15 从 `setsid nohup` 改为 systemd 托管（unit 由
`rehearsal_env/bootstrap_pf.sh` 生成），消掉原「重启后不自启」的坑。unit 内固定了
`HOME=/root`、`KUBECONFIG=/root/.kube/config`、`AWS_REGION=us-east-1`。

## 7. 接入方式

```bash
# 登录（--region 必带：shell 的 AWS_REGION 环境变量会覆盖配置文件）
aws ssm start-session --target <BastionId> --region us-east-1

# ★ Agent 会话：停在 ec2-user，不要 sudo su -（Kiro CLI 与登录态都在 ec2-user 下）
cd ~/canal_cutover_agent
source session_init.sh                       # 加载 env.sh + PATH，打印 pf 服务状态
kiro-cli-chat chat --agent canal-cutover

# Admin UI（两级隧道：本地 SSM 端口转发 → 跳板机 port-forward → pod）
aws ssm start-session --target <BastionId> --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8089"],"localPortNumber":["8089"]}'

# 纯脚本 / root 兜底路径
sudo su - && source /root/canal_cutover_agent/session_init.sh
```

本地远程驱动（不登录跳板机）：`rehearsal_env/ssm_run.sh 'kubectl get nodes'`。

## 8. 重启恢复清单（实例重启/替换后依序执行）

以 ec2-user 执行（不要 sudo su -）：

```bash
cd ~/canal_cutover_agent && source session_init.sh        # 凭证 + PATH（会打印 pf 服务状态）
aws eks update-kubeconfig --name canal-rehearsal --region us-east-1   # 仅实例替换后需要
systemctl status canal-admin-pf                           # Admin UI 通道：已 systemd 自启，确认即可
rm -f state/run_*/loadgen.pid                             # 清陈旧 pid
bash scripts/40_loadgen.sh start                          # 造数端
bash scripts/00_env_assert.sh                             # P0 断言确认环境健康
kiro-cli whoami                                           # 确认 CLI 登录态未过期
```

实例被 CDK **替换**（非重启）时额外需要，依序：

1. 重跑 bootstrap 全链（`bootstrap_db.sh` 起，见 rehearsal_env/README「脚本化路径」）——
   `~/.canal/secrets.sh` 随实例消失，口令必须重建
2. 重装 Kiro CLI 并 `kiro-cli login`（需交互，无法脚本化）
3. `./deploy_agent_assets.sh`（root 侧资产）+ `./ssm_run.sh -f setup_cli_agent.sh`（ec2-user 侧资产与 agent 配置）

## 9. 已知坑（均已踩过并留档）

1. SSM RunCommand 环境无 HOME → kubectl 找不到 kubeconfig 连 localhost:8080，脚本需
   `export HOME=/root` + `export KUBECONFIG=/root/.kube/config`（已内置进 `ssm_run.sh` 前导）
2. `aws ssm start-session` 不带 --region 时被 shell 环境变量带偏 → TargetNotConnected
3. /tmp 是 tmpfs，重启清空（Kiro CLI 会话日志因此丢过一次）——重要证据落 state/ 目录
4. t3.micro 内存不足以承载 Kiro CLI 会话 + kubectl 常驻（OOM 宕机史）
5. ~~常驻进程非 systemd 托管~~ → 2026-08-15 已改 systemd（见第 6 节），此坑消除
6. 口令集中在 `/home/ec2-user/.canal/secrets.sh`（600, ec2-user）：`PRIMARY/READER/
   DBADMIN_PWD/CANAL_ADMIN_PWD/CANAL_PWD/ADMIN_PASSWD/BROKERS`；`/root/canal_env.sh`
   与 `/root/msk_env.sh` 是指向它的 shim。两侧 `env.sh` 都只 source、不含明文——
   **实例替换后该文件消失，需重跑 bootstrap 脚本重建**
7. **Kiro CLI 装在 ec2-user 下，runbook 资产原先在 /root——身份错配**：agent 会话必然以
   ec2-user 运行，读不到 `/root`（600）。2026-08-15 已把操作身份统一到 ec2-user（见第 4 节）。
   症状提示：以 root 跑 `kiro-cli-chat` 会因 `/root/.kiro` 无登录态而要求重新认证
8. **CLI agent 只放全局一份**：项目级 `.kiro/agents/` 与全局 `~/.kiro/agents/` 同时存在
   同名 agent 时，每次 `agent list`/启动都打印
   `WARNING: Agent conflict for canal-cutover. Using workspace version.`——
   切割现场不该有这种噪音。因 agent 定义内的 `resources` 与 runbook 根路径都是**绝对路径**，
   只留全局一份即可从任意目录启动，行为一致且无警告
9. `kiro-cli-chat chat` 的非交互冒烟用 `--no-interactive --trust-tools=fs_read`：
   只给读权限、拿不到 shell，可零风险验证「定义加载 / 提示词生效 / 门禁规则已内化」。
   **绝不要用 `--trust-all-tools`**——那等于拆掉 agent 的门禁
