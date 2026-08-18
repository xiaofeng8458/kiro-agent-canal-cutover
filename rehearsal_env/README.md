# 蓝绿切割演练环境（CDK，EKS 版）

复刻生产形态的演练环境，缺省部署在 **us-east-1**。
**不创建 VPC**：必须用 `-c vpcId=vpc-xxx` 指定现有 VPC，未提供直接报错。

```
┌───────────────────────── 现有 VPC（-c vpcId 指定，最少 2 AZ）───────────────────────────────┐
│ Public subnet          Private (app) subnets              Private/isolated (data) subnets   │
│ ┌────────────────┐     ┌─────────────────────────┐        ┌───────────────────────────────┐ │
│ │Bastion t3.medium│     │ EKS 1.35 节点组 t3.large │  3306  │ RDS MySQL 8.0 primary ─► reader│ │
│ │ kubectl + mysql │────►│  ├ zookeeper × 1        │ ─────► │ (db.t4g.micro, GTID ON, 加密)  │ │
│ │ (零 inbound,    │     │  ├ canal-admin × 2      │        ├───────────────────────────────┤ │
│ │  SSM 接入)      │     │  └ canal-server × 1     │  9092  │ MSK kafka.t3.small × 2（加密） │ │
│ └────────────────┘     └─────────────────────────┘ ─────► │                               │ │
│                          EKS 控制面（托管）                └───────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

与生产一致的关键点：canal 官方镜像 + app.sh（admin 托管 `restart.sh local`）、
`canal-server-0` StatefulSet + headless service、namespace `common-service`、
位点在 ZK（default-instance.xml）、canal_manager 库在 MySQL、Canal 订阅**只读副本**、
运维从跳板机操作 kubectl/mysql。因此 `canal_cutover_agent/scripts/` 可在本环境原样演练。

## 成本估算（us-east-1 按需，约）

| 资源 | 规格 | 月成本 |
|---|---|---|
| EKS 控制面 | 标准支持版本 | ~$73 |
| 节点组 | t3.large ×1 + 30GB gp3 | ~$63 |
| RDS × 2 | db.t4g.micro + 20GB gp3 | ~$28 |
| MSK × 2 broker | kafka.t3.small + 20GB | ~$69 |
| Bastion | t3.medium + 10GB gp3 | ~$31 |
| **合计** | | **~$264/月 ≈ $9/天** |

（跳板机原为 t3.micro，实测扛不住 Kiro CLI 会话 + kubectl 常驻，OOM 宕机后升到 t3.medium；
纯脚本运维可降回 small。）

（NAT/网络费用不在本栈内——复用现有 VPC 的 NAT，EKS 节点拉镜像会产生少量 NAT 流量费。）

演练按天计：**用完立即 `cdk destroy`**。中途暂停可 stop Bastion 与 RDS、节点组缩到 0
（EKS 控制面与 MSK 不支持停止，长挂机不划算）。

## 现有 VPC 的前置要求（synth 时硬校验，不满足会明确报错）

| 要求 | 用途 | 不满足时 |
|---|---|---|
| **必须提供 `-c vpcId=vpc-xxx`** | 本栈不创建 VPC | 直接报错退出 |
| 带 NAT 出网的 private 子网 ≥ 1 | EKS 节点组（拉镜像/访问控制面） | 报错退出 |
| isolated 或 private 子网覆盖 ≥ 2 AZ | RDS 子网组 + MSK（最少 2 AZ） | 报错退出 |
| public 子网（可选） | 跳板机；没有则跳板机落 private 子网（SSM 经 NAT 仍可接入） | 自动降级 |

子网选择规则：RDS/MSK 优先用 isolated 子网，VPC 没有 isolated 时退用 private；
MSK 在数据子网中每个 AZ 取一个、共两个。

## 部署

```bash
cd rehearsal_env
npm install
npx cdk bootstrap                          # 账号首次使用 CDK 才需要
npx cdk deploy -c vpcId=vpc-xxxxxxxxxxxx   # EKS 创建约 15-20 分钟；记下全部 Outputs
```

注意：`Vpc.fromLookup` 需要部署凭证做一次 VPC 查询（结果缓存在 cdk.context.json）。

```bash
# BastionId 每次重建都会变，以本次栈 Outputs 为准（source ./stack_outputs.sh 会导出 BASTION_ID）
aws ssm start-session --target <BastionId> --region us-east-1
```

登陆后：
```bash
sudo su -                                                        # 切 root
aws eks update-kubeconfig --name canal-rehearsal --region us-east-1   # 首次登录配置 kubectl
kubectl get nodes                                                # 验证：应看到 1 个 Ready 节点
```

## 部署后配置：脚本化路径（推荐，约 10 分钟）

2026-08-15 重建时把原本 30 分钟的手工步骤（含 Admin UI 点击）全部脚本化，
**本地有 AWS 凭证即可驱动，无需交互式登录跳板机、无需浏览器**。
机制：`ssm_run.sh` 经 SSM `send-command` 把脚本整段送到跳板机执行并回传输出。

```bash
cd rehearsal_env
source ./stack_outputs.sh                 # 从栈 Outputs 导出 BASTION_ID / endpoint / secret 名 / MSK ARN
./ssm_run.sh 'kubectl get nodes'          # 连通性自检

./ssm_run.sh -f bootstrap_db.sh           # 建库/账号/marker 表/binlog 保留 168h
./ssm_run.sh -f bootstrap_pf.sh           # canal-admin port-forward 交给 systemd
# k8s manifests 送上去并部署 ZK
./ssm_run.sh -f extract_templates.sh      # 从镜像取 canal.properties/instance.properties 模板 + MSK bootstrap
./ssm_run.sh -f bootstrap_admin.sh        # 导入 canal_manager 表 + secret + 部署 canal-admin
./ssm_run.sh -f bootstrap_cluster.sh      # 改默认口令 + 建 rehearsal 集群 + 下发主配置
./ssm_run.sh -f bootstrap_server.sh       # 部署 canal-server，确认注册
./ssm_run.sh -f bootstrap_instance.sh     # 建 instance server-0（订阅 reader）
./ssm_run.sh -f fix_instance_cluster.sh   # 补 instance 归属并以 ZK 为判据确认接管
TIMEOUT=900 ./ssm_run.sh -f verify_e2e.sh # 端到端：建 topic → 写 marker → Kafka 消费 → cursor 推进

./deploy_agent_assets.sh                  # 把 runbook 资产 + env.sh + session_init.sh 装到跳板机（root 侧）
./ssm_run.sh 'cd /root/canal_cutover_agent && bash scripts/00_env_assert.sh'   # P0 验收
```

装完 Kiro CLI（需人工登录认证）后，再配 CLI agent：

```bash
./ssm_run.sh -f setup_cli_agent.sh        # 口令收敛 + ec2-user 侧资产 + agent 装到 ~/.kiro/agents + validate
./ssm_run.sh -f smoke_cli_agent.sh        # 只读冒烟（--trust-tools=fs_read，拿不到 shell）
```

`ssm_run.sh -f <脚本> [参数...]` 支持把参数转发给远端脚本（如
`./ssm_run.sh -f compat84_parse_check.sh sha2 true`）。

**环境标识不硬编码在仓库里。** `stack_outputs.sh` 从 CloudFormation 栈 Outputs 读出
`BASTION_ID` / `PRIMARY_ENDPOINT` / `READER_ENDPOINT` / `DB_SECRET_NAME` / `MSK_CLUSTER_ARN`
并导出；`ssm_run.sh` 把这几个（**只有这几个非敏感标识，口令不走这条路**）透传到跳板机，
远端脚本因此不需要写死任何 endpoint 或 ARN。忘了 source 会在脚本第一行报缺变量，不会跑错库。

switchover 后的修补脚本额外需要两个基准值（刻意不给默认值）：

```bash
export GREEN_READER_ENDPOINT='<逐成员核对后确认的绿 reader endpoint>'   # 见 §3.1 的核对方法
export OLD_CURSOR_GTID='<state/cursor_backup_*.json 里的 postion.gtid>'
export ARCHIVED_TS='<同一份存档的 postion.timestamp 毫秒值>'
./ssm_run.sh -f fix_post_switchover.sh
```

`setup_cli_agent.sh` 解决的是**身份错配**：Kiro CLI 装在 ec2-user 下、登录态也在那儿，
agent 会话必然以 ec2-user 运行，读不到 `/root`（600）的资产与口令。它把 runbook 操作身份
统一到 ec2-user，口令收敛到 `~/.canal/secrets.sh` 单一权威位置，`/root` 侧留 shim
保证既有 bootstrap 脚本不断。详见 `bastion_host.md` 第 4 节。

**口令与凭证一律不落本地**：dbadmin 从 Secrets Manager 取，canal / canal_admin / Admin UI
口令在跳板机上生成，只写 `/root/canal_env.sh`（600）；`env.sh` 只 source 它，不含明文。

`ssm_run.sh` 内置前导 `HOME=/root` 与 `KUBECONFIG=/root/.kube/config`——SSM RunShellScript
虽以 root 运行但 HOME 不是 /root，缺这两行 kubectl 会去连 localhost:8080。

下面的手工步骤保留作为原理说明与兜底路径。

## 部署后配置：手工路径（原理说明 / 兜底，约 30 分钟）

1. **SSM 登录跳板机**（Outputs 的 SsmConnect 命令），配置 kubectl 并确认集群就绪：
   ```bash
   aws eks update-kubeconfig --name canal-rehearsal --region us-east-1
   kubectl get nodes   # 预期 1 个 Ready 节点
   ```
   （跳板机角色已写入集群 aws-auth，无需额外授权。）

2. **初始化数据库**：从 Secrets Manager 取 dbadmin 密码（Outputs 的 DbSecretName），
   替换 `sql/init_canal.sql` 中两处密码占位符后执行：
   ```bash
   mysql -h <PrimaryEndpoint> -u dbadmin -p < init_canal.sql
   ```

3. **部署 ZK 与 namespace**：
   ```bash
   kubectl apply -f k8s/00-namespace.yaml -f k8s/10-zookeeper.yaml
   kubectl -n common-service get pvc   # EBS CSI addon 已随栈安装，PVC 应变为 Bound
   ```

4. **创建 canal-admin 的 DB 凭证 secret**（用第 2 步的 canal_admin 账号）：
   ```bash
   kubectl -n common-service create secret generic canal-admin-db \
     --from-literal=address='<PrimaryEndpoint>:3306' \
     --from-literal=username='canal_admin' \
     --from-literal=password='<PASSWORD_1>'
   ```

5. **导入 canal_manager 表结构**（官方脚本，含 `CREATE DATABASE` / `USE`）：
   ```bash
   curl -LO https://raw.githubusercontent.com/alibaba/canal/canal-1.1.8/admin/admin-web/src/main/resources/canal_manager.sql
   mysql -h <PrimaryEndpoint> -u dbadmin -p canal_manager < canal_manager.sql
   ```

6. **部署 canal-admin，创建集群**：
   ```bash
   kubectl apply -f k8s/20-canal-admin.yaml
   # 本地访问 Admin UI：跳板机上 port-forward，再用 SSM 端口转发到本地
   #   跳板机: kubectl -n common-service port-forward svc/canal-admin 8089:8089 --address 127.0.0.1 &
   #   本地:   aws ssm start-session --target <BastionId> --region us-east-1 \
   #             --document-name AWS-StartPortForwardingSession \
   #             --parameters '{"portNumber":["8089"],"localPortNumber":["8089"]}'
   #   （--region 必带：shell 里若有 AWS_REGION/AWS_DEFAULT_REGION 环境变量指向别的区，
   #     会报 TargetNotConnected，即使 ~/.aws/config 的默认区是对的）
   ```
   浏览器打开 http://localhost:8089（默认 admin/123456，**登录后立即改密**）：
   - 集群管理 → 新建集群：名称 `rehearsal`（必须与 30-canal-server.yaml 的 register.cluster 一致），
     ZK 地址 `zookeeper.common-service:2181`
   - 集群 → 主配置 → 载入模板，修改四处：
     ```properties
     canal.zkServers = zookeeper.common-service:2181
     canal.instance.global.spring.xml = classpath:spring/default-instance.xml
     canal.serverMode = kafka
     kafka.bootstrap.servers = <MSK plaintext bootstrap，用 Outputs 的 MskBootstrapCmd 获取>
     ```

7. **部署 canal-server**（自动注册进 rehearsal 集群）：
   ```bash
   kubectl apply -f k8s/30-canal-server.yaml
   kubectl -n common-service get pods   # 预期 canal-server-0 Running
   ```

8. **创建 instance**：Admin UI → Instance 管理 → 新建，载入模板并修改：
   ```properties
   # 订阅只读副本（与生产一致）。
   # ⚠️ properties 不支持行内注释，值的行尾不能追加 "# ..."，也不能留尾随空格
   canal.instance.master.address = <ReaderEndpoint>:3306
   canal.instance.dbUsername = canal
   canal.instance.dbPassword = <PASSWORD_2>
   canal.instance.gtidon = true
   canal.mq.topic = biz_test
   ```

9. **验证链路**（跳板机执行）：

   ```bash
   BROKERS=$(aws kafka get-bootstrap-brokers --cluster-arn <MskClusterArn> \
     --query BootstrapBrokerString --output text)

   # a. 建 topic（MSK 默认关闭自动建 topic，必须手工建；
   #    Kafka CLI 用临时 pod 跑，镜像用 apache/kafka——bitnami 老 tag 已从 Docker Hub 下架）
   kubectl run kafka-admin --rm --restart=Never --image=apache/kafka:3.7.0 -- \
     sh -c "/opt/kafka/bin/kafka-topics.sh --bootstrap-server $BROKERS \
       --create --if-not-exists --topic biz_test --partitions 1 --replication-factor 2"

   # b. 写 marker 行（写主库，Canal 从 reader 的 binlog 获取）
   mysql -h <PrimaryEndpoint> -u dbadmin -p -e \
     "INSERT INTO biz_test.marker(tag) VALUES ('e2e-test');"

   # c. Kafka 侧消费验证（预期收到 type=INSERT、table=marker 的 JSON）
   #    注意别用 kubectl run -it：首次拉镜像超过 attach 超时会误报失败
   kubectl run kafka-consumer --restart=Never --image=apache/kafka:3.7.0 -- \
     sh -c "/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BROKERS \
       --topic biz_test --from-beginning --max-messages 3 --timeout-ms 30000"
   sleep 40 && kubectl logs kafka-consumer && kubectl delete pod kafka-consumer

   # d. ZK cursor 验证（gtid 字段非空且随写入推进）
   kubectl -n common-service exec zookeeper-0 -- \
     zkCli.sh -server localhost:2181 get /otter/canal/destinations/<instance>/1001/cursor
   ```

## 演练蓝绿切割

推荐形态是 **canal-cutover agent 驱动、人只守门禁**（分工表与三层可用性见
`../README.md` 使用方式一节；agent 的职责边界见 `../steering/canal-cutover-runbook.md` 3.5 节）。

1. 准备：把 canal_cutover_agent 传到跳板机；复制 env.sh.sample 为 env.sh 按本环境填写
   （ZK_NS=common-service、ZK_POD=zookeeper-0、DESTINATION=server-0、
   ADMIN_API=http://127.0.0.1:8089 经 port-forward）；启动造数端持续写 marker；
   创建 8.4 参数组（gtid-mode=ON）；
2. 控制台/CLI 对 primary 创建 Blue/Green Deployment（目标 8.4）——始终人工执行；
   绿就绪后做 **8.4 兼容性预检**（临时 instance 指绿 reader 临时 endpoint，分别定性：
   认证方式、SHOW BINARY LOG STATUS 适配、报文解析——canal 1.1.8 + caching_sha2
   已实锤必崩，native 在 8.4 默认被禁，此步必须给出落地解）；
3. Agent 会话中按 `P0 → P1 → [人工 switchover] → 20..24 → P3` 完整演练；
4. 对账收尾：Kafka 消费的 marker id 集合 ⊇ 源库 id 集合（允许重复不允许缺失）；
   第二轮可演故障路径（不修位点直接切，验证 1236 分诊）；
5. 演练同时是 agent 的验收测试：门禁、失败即停、故障分诊三项行为必须验证通过。

## 跳板机配置档案

跳板机的完整环境配置（基础设施/IAM/软件/目录/常驻进程/接入方式/重启恢复清单/已知坑）
集中整理在 **[bastion_host.md](./bastion_host.md)**。

## 安全基线说明

- RDS / MSK：无公网访问、存储加密、SG 仅放行 EKS 节点组与跳板机
- EKS：节点在私有子网经 NAT 出网；跳板机角色最小授权后写入 aws-auth
- 跳板机：**零 inbound 规则**（SSM Session Manager 接入，无 SSH 密钥）、IMDSv2 强制、EBS 加密
- 凭证：dbadmin 由 Secrets Manager 生成；canal 账号密码不落盘（K8s secret + Admin UI）
- 成本取舍处（生产不可照搬）：EKS API endpoint 为 PUBLIC_AND_PRIVATE（生产应改 PRIVATE
  或限制来源 CIDR）、EBS CSI 权限挂在节点角色（生产应用 IRSA/Pod Identity）、
  MSK 允许 VPC 内 PLAINTEXT（9092）、RDS 单 AZ、单 NAT

## ⚠️ 重大发现（2026-07-22 环境搭建实测）

**canal 1.1.8 官方镜像 + `caching_sha2_password` 账号 = parser 必崩**（RDS MySQL 8.0.42 实测）。
认证本身成功，但认证后的首个查询即报 `ArrayIndexOutOfBoundsException`
（`EOFPacket.fromBytes` / `readBinaryCodedLengthBytes`，报文流错位）。
A/B 实锤：仅把 canal 账号 `ALTER USER ... IDENTIFIED WITH mysql_native_password` 后立即恢复正常。
与 [alibaba/canal#5403](https://github.com/alibaba/canal/issues/5403)（8.0.36 同栈报错）一致，上游未修复。

**对生产升级方案的影响**：常见的升级前建议里有一条"提前把 Canal 账号迁到
caching_sha2_password"（因为 8.4 弃用了 native），与本发现直接冲突。请在你实际使用的
Canal 版本上复测后再决定，不要照抄。

⚠️ 本节第二段原有的「8.4 默认禁用 mysql_native_password，需在 8.4 参数组显式开启」
**已被 2026-08-15 实测推翻**，见下一节。

## 8.4 兼容性预检结论（2026-08-15，RDS MySQL 8.4.10 实测）

方法：另建临时独立实例 `canal-compat84-tmp`（db.t4g.micro / 8.4.10 / 参数组
`canal-rehearsal-84`），用一次性隔离 pod 起 canal-server（local + `file-instance.xml` 不写 ZK、
`tcp` 模式不碰 Kafka）指向它，完全不干扰演练链路。脚本：`compat84_db_checks.sh`、
`compat84_parse_check.sh`。测完即销毁。

| 预检项 | 结论 | 证据 |
|---|---|---|
| 认证方式 | ✅ **native 在 RDS 8.4 可用** | `mysql_native_password` 插件 `ACTIVE`；参数值 `ON` 且 **`IsModifiable=false`**（AWS 不允许关闭）；native 账号创建并连接成功 |
| 语法适配 | ✅ **canal 1.1.8 自带版本分支，无需改造** | 见下方说明 |
| 报文解析 | ✅ 零异常，DML+DDL 均正常解析 | `produce_seq` 0→9、`received_binlog_bytes>0`、日志 `exception/error` 计数 0 |

**语法适配的细节（反直觉，务必记住）**：8.4 已移除 `SHOW MASTER STATUS` 与
`SHOW SLAVE STATUS`（实测均报 `ERROR 1064`），替代语句是 8.2 引入的
`SHOW BINARY LOG STATUS` / `SHOW REPLICA STATUS`
（[MySQL 8.4 变更清单](https://dev.mysql.com/doc/refman/8.4/en/added-deprecated-removed.html)）。
而 canal 1.1.8 的寻位日志会打印 `prepare to find start position just show master status`——
**这是过时的硬编码 WARN 文案，不代表它真的发了这条语句**。实证：
`canal.parse-1.1.8.jar` 的 `MysqlEventParser.class` 常量池里**同时**存在
`show master status` 与 `show binary log status` 两个字符串，且在 8.4.10 上寻位成功
（拿到真实 journalName/position/gtid）。**不要因为看到那行日志就误判为不兼容。**

**caching_sha2 的意外结果（结论有明确适用范围，勿外推）**：在 8.4.10 上对
`caching_sha2_password` 账号做了 A/B——`tsdb.enable` 开与关各一轮，**均未复现崩溃**：
认证成功、`Binlog Dump GTID` 正常、DML 与 DDL 都解析、零异常；服务端
`information_schema.processlist` 已复核连接身份确为 `canal_sha2`（插件 `caching_sha2_password`）。

- 因此上文「canal 1.1.8 + caching_sha2 必崩」的适用范围应收窄为 **RDS MySQL 8.0.4x**，
  而非 canal 与该插件的固有不兼容。
- ⚠️ **但本次并未重跑 8.0.42 上的那组 A/B**，所以不能断定原结论有误，只能说
  **在 8.4.10 上不复现**。要闭环需在 8.0.42 上再做一次对照（成本约 5 分钟：
  在蓝库建一个 caching_sha2 账号 + 一个一次性 pod 指向蓝 reader）。
- 演练与切割仍按 `mysql_native_password` 执行——它在 8.0.42 与 8.4.10 上都已实测可用，
  是唯一被双版本验证过的选项。

**本环境当前状态**：`bootstrap_db.sh` 已把这条结论固化——canal 复制账号建成
`mysql_native_password`，canal_admin 仍用 `caching_sha2_password`（Java 侧无此问题）。
`sql/init_canal.sql` 保留 caching_sha2 写法作为"原始建议"的记录，与实际部署刻意不一致。
2026-08-15 重建实测：canal-server 订阅 reader 全程无 `ArrayIndexOutOfBoundsException`，
反证了认证插件是该崩溃的唯一变量。

## 环境搭建实测踩坑记录（按遭遇顺序）

1. Admin UI 主配置必须先「载入模板」再改，只存 4 行会导致 canal-server NPE 崩溃（断开状态）
2. instance 配置是 properties：不支持行内注释、不容忍尾随空格（address 端口解析失败）
3. 集群模板的 `canal.destinations = example` 必须清空（Admin 托管模式下静态 destinations 会找不到配置）
4. canal-admin 1.1.8：DB 连接串需 `allowPublicKeyRetrieval=true`；`canal.adminPasswd` 不允许为空
5. EKS 1.30+ 无默认 StorageClass；EBS CSI 凭证需 Pod Identity（节点 IMDS hop limit=1）
6. bitnami 老镜像 tag 已从 Docker Hub 下架，Kafka CLI 用 `apache/kafka:3.7.0`

### 2026-08-15 重建新增（脚本化过程中实测）

7. **SSM RunShellScript 无 HOME**：以 root 运行但 `HOME` 不是 `/root`，kubectl 退回
   `localhost:8080` 报连接拒绝。脚本必须自带 `export HOME=/root; export KUBECONFIG=/root/.kube/config`
8. **canal-admin 口令哈希是双层 SHA1**：`UPPER(SHA1(UNHEX(SHA1(pwd))))`，即 MySQL 4.1
   `PASSWORD()` 的算法（默认行 `6BB4837E...441` = 双层 SHA1 of `123456`）。
   按单层 SHA1 改密会把自己锁在门外
9. **Admin 无模板接口**：UI 的「载入模板」是纯前端行为，REST 侧 `/templates`、`/canalConfig`
   全 404。模板从 `canal/canal-server:v1.1.8` 镜像的 `/home/admin/canal-server/conf/` 取
10. **主配置保存只有 PUT**：`POST /api/v1/canal/config` 返回 405 Method Not Allowed
11. **instance 创建必须 POST，PUT 会静默骗人**：`PUT /api/v1/canal/instance` 对不存在的行
    返回 `code:20000 success` 但一行都不落库。另外归属主机字段是复合串 `clusterServerId`，
    只传 `clusterId` 被拒（`empty cluster or server id`）；但传 `"1:1"` 落库后 `cluster_id`
    仍是 NULL，导致 canal-server 永远看不到该 instance（ZK destinations 空、runningStatus=0）。
    真实拼法在懒加载的前端 chunk 里，追查成本过高，现按
    `UPDATE canal_instance_config SET cluster_id=1, content_md5=MD5(content)` 补齐——
    canal-server 是按「本集群配置行存在性」轮询的，6 秒内即接管。**判据只看 ZK，不看 API 返回**
12. **Kafka 侧消费别按行数计数**：canal 把同一事务的多行合并成 **1 条** Kafka 消息
    （`data[]` 装 5 行）。`kafka-console-consumer --max-messages` 按行数给会等不满，
    以 `TimeoutException` 收尾，看起来像链路故障，实际是假故障
13. **port-forward 交给 systemd**（`canal-admin-pf.service`，enabled+active）替代原 `setsid nohup`
    裸跑，消掉「重启后常驻进程不自启」这条老坑
14. **单节点 CPU 请求很紧**：t3.large（2 vCPU）跑完 zookeeper + canal-admin×2 + canal-server
    后余量不多，再起 2 个测试 pod 就会 `FailedScheduling: Insufficient cpu`。
    临时验证 pod 用完立即删，或把 requests 调小
15. **RDS 8.4 上 `performance_schema` 默认关闭**（db.t4g.micro 实测 `@@performance_schema=0`），
    想用 `events_statements_summary_by_digest` 反查客户端发了什么语句会拿到空表——
    改用「读 jar 常量池」这类离线取证手段
16. **别在 `ssm_run.sh` 里跑遍历上百个 jar 的循环**：`unzip -p` 逐个解压加管道会跑到
    SSM 命令超时且难中断。定点解压目标 class 再 `strings`，并加 `timeout` 兜底
