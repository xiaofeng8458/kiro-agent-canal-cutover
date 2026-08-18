# Canal 蓝绿切割 Runbook Agent

把 RDS for MySQL 8.0 → 8.4 蓝绿切换的 **Canal 位点修补 Runbook，工程化成带可执行门禁的资产**：
一套复刻生产形态的演练环境、一组证据驱动的分级脚本、一个被权限和契约约束住的
Kiro custom agent。人只在门禁点按批准。

> 📝 配套博客（第二篇）：_待补链接（发布后填入）_
> ｜前篇讲 `errno = 1236` 的成因、并集修补公式与生产 Runbook，本仓库承接它的下一步。
>
> **不是 AWS 官方产品或托管服务，按现状提供。** 脚本会连你的数据库、改 Canal 配置、
> 创建会计费的 AWS 资源。先读[免责与适用范围](#免责与适用范围)，**务必先在演练环境跑通**。
> 仓库内所有账号 ID、VPC/实例 ID、endpoint、ARN 均为示例占位符。

四节读完就能上手：[这是什么](#1-这是什么) ·
[Kiro custom agent 是什么](#2-kiro-custom-agent-是什么) ·
[权限与 SOP 怎么控制](#3-权限与-sop-怎么控制) ·
[安装与使用](#4-安装与使用)

---

## 1. 这是什么

### 要解决的问题：Runbook 写对，不等于切割当晚做对

蓝绿切换后 Canal 位点为什么要修补、`errno = 1236` 怎么来的、并集公式怎么推——那是**另一件事**，
在配套博客的前篇里有完整推导，本仓库不重复。这里要解决的是它的下一个问题：**有了一份写对的
切割 Runbook，怎么保证切割当晚真的按它做。**

这个担心来自一次真实的位点操作事故复盘。位点修补的五步顺序是军规：

```
停实例 → 存档 → 清存量位点 → 验配置 → 启动
```

一旦颠倒，存量位点会压制新配置，**当场不报错**——要到下游对账时才暴露。而切割窗口本身
就是放大器：深夜，几十条命令，十几处判据要人眼比对，全组人守在你身后，还可能随时遇上故障。

把 Runbook 落到生产，有三个问题绕不过去：

| 问题 | 说明 | 本仓库的答案 |
|---|---|---|
| **在哪里练** | 必须在与生产**形态一致**的环境里完整走通。形态一致不等于版本号一致——位点存 ZooKeeper 还是文件、配置归 Admin 管还是本地文件、Canal 订阅主库还是只读副本，每一项都改变操作路径与判据 | `rehearsal_env/` 的 CDK 栈，按天创建销毁 |
| **由谁执行** | 窗口内几十条命令、十几处判据。纯人工慢且易错；全自动不可接受——停实例、删位点必须有人把关 | 一个被权限和契约约束住的 agent，人只守门禁点 |
| **怎么防误操作** | 顺序和判据不能指望执行人足够小心。防线要建在流程里，而不是写在提示词里 | 三层防线：工具白名单 + 行为契约 + 脚本内置 `YES` |

三个问题指向同一件事：**Runbook 必须工程化成可验证、可复用的资产**。这个仓库就是那套资产。

### 仓库提供什么

| 组成 | 位置 | 作用 |
|---|---|---|
| Agent 定义 | `agents/` | 谁来执行：工具面 + 权限策略 + 行为契约 |
| Runbook 知识库 | `steering/canal-cutover-runbook.md` | 按什么执行：环境事实、流程、判据、门禁规则、故障判定表 |
| 分级脚本 | `scripts/` | 用什么执行：00–51 号脚本，按只读 / 仅写测试表 / 门禁变更分级 |
| 演练环境 | `rehearsal_env/` | 在哪演练：EKS + RDS 主从 + MSK + SSM 跳板机的 CDK 栈 |
| 操作手册 | `REHEARSAL_OPERATOR_RUNBOOK.md` | 人照着走的那份：每阶段说什么、盯什么、在哪按门禁 |
| 演练报告 | `reports/` | 两轮真实演练：判据结果、踩坑清单、agent 行为验收 |

脚本按阶段编号，编号顺序就是执行顺序：

| 脚本 | 阶段 | 类型 |
|---|---|---|
| `00_env_assert.sh` | P0 环境断言 | 只读 |
| `10_preflight_gtid.sh` | P1 GTID 预检 + 并集生成 | 只读 |
| `20_stop_instance.sh` | P2 停 instance | **门禁** |
| `21_archive_cursor.sh` | P2 存档 cursor | 只读 |
| `22_delete_cursor.sh` | P2 删除 cursor 节点 | **门禁** |
| `23_verify_config.sh` | P2 校验 `master.gtid` 配置 | 只读 |
| `24_start_instance.sh` | P2 启动 instance | **门禁** |
| `30_verify.sh` | P3 验证循环 | 只读 |
| `40_loadgen.sh` | 造数端（基准流量） | 仅写测试表 |
| `50_e2e_verify.sh` | 端到端：marker → Kafka | 仅写测试表 |
| `51_reconcile.sh` | 数据完整性对账 | 只读 + Kafka 消费 |

`scripts/lib/common.sh` 提供环境加载、日志、`YES` 门禁与 Canal Admin REST 封装。
每个阶段的通过判据见 `steering/canal-cutover-runbook.md` 第 3 节的流程映射表。

**本项目的演练与验证对象是 Kiro CLI（堡垒机上的会话）。** agent 定义同时兼容 Kiro IDE
——把 `agents/canal-cutover.md` 放进工作区 `.kiro/agents/` 即可在 agent 选择器里看到它
——但 IDE 侧没有作为本项目的演练与行为验收对象，下文一律以 CLI 为准。

---

## 2. Kiro custom agent 是什么

[Kiro](https://kiro.dev/) 是 AWS 的 agentic AI 开发环境。在 Kiro 里定义一个 custom agent，
写一个 `.md` 文件就够了，这个文件分两半：

- **上半段 YAML**——它能用哪些工具，哪些命令可以直接跑、哪些要人点头、哪些一律不许
  （[能力级权限](https://kiro.dev/docs/permissions/)，`allow` / `ask` / `deny`）；
- **下半段正文**——它在这个任务里的行为契约，也就是系统提示词。

加载之后你得到的不是通用助手，而是一个**作用域被收窄过的执行者**。

### 这个场景该不该交给 agent

在切割这种一次性、强时序、错了要靠对账才发现的场景里，可靠性不来自"模型更聪明"，
而来自三件事：**把动作限制成可枚举集合、用可复查的证据验证结论、把不可逆的决定留给人**。

判断一个运维场景该不该交出去，用下面六条，**全中才做**：

| 准入条件 | 蓝绿切割位点修补的情况 |
|---|---|
| 操作序列确定 | "停 → 档 → 清 → 验 → 启"五步，顺序本身就是军规 |
| 判据可机器判定 | `GTID_SUBSET` 返回 1、`stat` 返回节点不存在、寻位日志 gtid 等于并集、`GTID_SUBTRACT` 差值收敛、Kafka id 集合覆盖源表 |
| 认知负荷高、创造性低 | 十几处判据比对、GTID 集合运算、跨日志取证，全是比对工作 |
| 失败可检测、回滚明确 | cursor 有存档可恢复；instance 可停；错误有 1236 这类明确信号 |
| 变更面可枚举 | 变更只经三个脚本；禁区是 switchover 与 RDS/K8s 变更命令 |
| 有证据可留档 | 每阶段实时写执行日志，流程结束时日志即报告底稿 |

这个场景还有一条加分项：**切割窗口在深夜，人的状态最差，agent 的状态恒定。**
把比对和取证交出去，人省下的注意力用在门禁判断上。

### Agent 承担的五类认知工作

它的价值不是"帮你敲命令"——那是脚本的活。它接的是脚本干不了的部分：

| # | Agent 承担的工作 | 为什么脚本干不了 |
|---|---|---|
| 1 | **判据比对** | 脚本只产出输出。对照 runbook 判据逐条打勾、给结论+证据行+下一步，是理解题 |
| 2 | **顺序状态机** | 守"停→档→清→验→启"军规。cursor 没删就去启动 instance——命令本身完全合法，只有理解流程的东西能拦 |
| 3 | **故障分诊** | 出现 1236 时第一动作抓 `GTID set sent by the replica` 与并集比对，按判定表区分"存量位点残留"还是"并集过期" |
| 4 | **动态取证** | 脚本没覆盖的环节（如目标版本兼容性预检）用只读命令自由组合取证 |
| 5 | **证据留档** | 每阶段证据实时写 `state/` 执行日志，流程结束时它就是报告底稿 |

### 切割中人和 agent 的分工

| 步骤 | Agent | 人 |
|---|---|---|
| P0/P1 预检 | 执行 + 给判据结论 | 看结论 |
| 停 instance（20） | 出示 动作/证据/回滚，等批准 | **批准** |
| 存档 cursor（21） | 自主执行 | — |
| **RDS switchover** | 提示"预检全绿可切换"，**到此为止** | **人工触发** |
| 重算并集（10） | 自主执行 | — |
| 删 cursor（22） | 出示计划，等批准 | **批准** |
| 配置校验（23） | 回读 DB 逐字比对 | 改配置 |
| 启动 instance（24） | 前置硬校验 + 出示计划，等批准 | **批准** |
| P3 验证（30） | 持续监测 + 故障分诊 | 看报告 |

⚠️ **agent 必须先在演练环境完整跑通一次切割（含门禁、失败即停、故障分诊三项行为验证），
才允许出现在生产切割中。** 演练同时是流程验证和 agent 的准入测试——
`REHEARSAL_OPERATOR_RUNBOOK.md` 第 6 节给了三项行为验收的制造方法。

### 什么时候**不要**用它

- **RDS switchover 的触发，以及走/停决策。** 这是禁区，永远由人执行。agent 的活到
  "预检全绿"为止，连"把命令递给你粘贴"都不允许。
- **演练环境的创建与销毁**（`cdk deploy` / `cleanup.sh`），由人执行。
- **环境形态不符**：位点存文件而非 ZooKeeper、配置不走 Admin 托管、非 GTID 模式。
  这些情况下 runbook 的判据和故障判定表都不成立，agent 会拿错误的判据打勾。
- **多 destination / 多 client id 的批量切割**：当前 runbook 只覆盖单条链路。
- **需要 DDL 或数据修复的补偿动作**：影响面写不出边界，不满足"变更面可枚举"。
- **无人值守模式**：门禁的前提是有人应答。若会话无法向人请示，agent 契约要求立即停止。
- **没在演练环境完整跑通过的环境**，不要直接上生产。

---

## 3. 权限与 SOP 怎么控制

### 三层防线，缺一不可

| 层 | 是什么 | 拦什么 | 在哪定义 |
|---|---|---|---|
| **声明式策略** | `permissions` 规则：只读脚本 `allow`、变更脚本 `ask`、禁区 `deny`，由 Kiro 运行时强制 | 禁区命令、未经人眼的变更 | `agents/canal-cutover.md` frontmatter（CLI 载体同源携带） |
| **行为契约** | agent 的系统提示词：顺序、判据、请示、失败即停 | "命令合法但时机错误" | `agents/canal-cutover.md` 正文 |
| **脚本内置门禁** | 变更脚本打印计划与回滚，要求逐字输入 `YES` | agent 或人的手滑 | `scripts/lib/common.sh` 的 `confirm()` |

三层的分工可以这样理解：策略判断"这条命令允不允许跑"，契约判断"现在该不该跑这一步"，
`YES` 确认是最后一道执行前的刹车。**策略拦不住顺序错误，契约拦不住被说服**，
所以真正危险的操作（switchover 触发、环境销毁）干脆不在脚本范围内，由人执行。

### 关于声明式 permissions：版本前提（重要）

`agents/canal-cutover.md` 的 frontmatter 里有一份 `permissions` 策略
（只读脚本 `allow`、变更脚本 `ask`、禁区 `deny`、只放开 `state/` 的写入、口令文件不可读）。
**这份策略是否被执行，取决于你跑在哪个版本上——这是本项目栽过跟头的地方：**

- **Kiro CLI 3.0（`kiro-cli --v3`）执行它。** CLI 3.0 与 IDE 共用同一 unified harness，
  官方文档明确 agent 内嵌 `permissions` 是被评估的作用域（`deny` > `ask` > `allow`，
  见 [kiro.dev/docs/cli/v3](https://kiro.dev/docs/cli/v3/)）。因此本仓库的
  `canal-cutover.cli.json` **携带与 md 完全相同的 permissions**（由 `gen_cli_json.sh` 生成），
  并以 **v3 启动为硬性前提**。
- **Kiro CLI 2.x 不执行它，而且不告警。** 实测（2.18.1）：配了 `deny` 的命令照样执行成功；
  `agent validate` 连瞎编的字段都返回退出码 0——"校验通过"不等于"规则生效"。
  在 2.x 会话里禁区命令没有任何机器拦截，那与本项目复盘里"配置被静默忽略"的事故
  属于同一失败类别。
- **文档结论要落地成实测结论。** `setup_cli_agent.sh` 部署时先做版本闸门（2.x 且无
  `--v3` 开关直接终止），再跑 **deny 冒烟探针**：探针 agent 配一条 allow、一条 deny，
  非交互跑一次，只看文件系统证据——allow 命令必须落盘、deny 命令必须被拦，
  探针不过不许开工。换任何 Kiro 版本，先重跑探针再决定依赖——不要假设新版本更严格。

### SOP 定义在哪

`steering/canal-cutover-runbook.md` 是 agent 的**唯一权威知识来源**，包含五块：

1. **环境事实表**——部署形态、位点存储、寻位优先级、已知脏数据、保护配置。
   agent 被要求：任何与此不符即中止并报告，禁止凭记忆推断环境状态。
2. **修补公式与两条硬性要求**：
   - `master.gtid` 必须配套 `master.timestamp`（TSDB 启用时缺它 canal 直接拒绝启动）；
   - switchover 后**第一动作**是在新主库重设并验证 binlog retention——retention 是实例
     本地配置，**绿环境不继承**，被清掉的区间会被并集标记为"已消费"= 真实丢数据且无告警。
     并集必须在 retention 确认后、用**当时最新的** `gtid_purged` 计算（purged 是移动靶）。
3. **流程与脚本映射表**——每个阶段跑哪个脚本、什么类型、通过判据是什么。
4. **验收矩阵**（P3 持续观察 ≥ 5 分钟）与**故障判定表**（1236 的两个分支及处置）。
5. **顺序军规**：

   ```
   停实例 → 存档 → 清存量位点 → 验配置 → 启动 → 验收
   ```

### 分级对应的行为

| 级别 | 脚本 | agent 的行为 |
|---|---|---|
| 只读 | 00 / 10 / 21 / 23 / 30 | 自主执行，结果与证据写入 `state/` |
| 仅写测试表 | 40 / 50 / 51 | 自主执行，写操作限于 `MARKER_TABLE` 指定的测试表 |
| 变更 | 20 / 22 / 24 | 先出示 动作+证据+回滚 请示，等批准；脚本再要 `YES` |
| 禁区 | switchover 触发、`cleanup.sh`、`cdk destroy`、异常中止决策 | 不在职责内，人执行 |

口令不落仓库：`env.sh` 已 gitignore；DB 密码走 `MYSQL_PWD` 或外部口令文件；演练环境的
dbadmin 口令由 Secrets Manager 托管，其余口令在跳板机本地生成、只落 600 权限的单一文件。
agent 定义里对 `*.pem` / `*.key` / `.env` / 口令文件是 `fs_read: deny`——脚本能加载，
agent 自己读不到明文。

### 改 SOP 的正确姿势

- 改**判据、流程、环境事实** → 改 `steering/canal-cutover-runbook.md`，agent 下次会话即生效。
- 改**权限或契约** → 改 `agents/canal-cutover.md`（唯一真源），然后必须跑
  `bash agents/gen_cli_json.sh` 重新生成 CLI 载体，两个文件一起提交。
  **不要手改 `agents/canal-cutover.cli.json`。**
- agent 被禁止改写 `scripts/`、`steering/`、`agents/`、`env.sh`——改了就等于自己给自己发许可证。

---

## 4. 安装与使用

四步：起演练环境 → 装 Kiro CLI 与 agent → 跑一次演练 → 适配到你的环境。

### 4.1 前置条件

| 项 | 要求 |
|---|---|
| Canal | 1.1.8，Admin 托管模式，位点存 ZooKeeper（`default-instance.xml`） |
| 数据库 | RDS for MySQL，`gtid-mode=ON` / `enforce_gtid_consistency=ON` / `binlog_format=ROW` |
| 运行环境 | bash 4+、`mysql` 客户端、`kubectl`、`jq`、`curl`、AWS CLI v2 |
| Agent | Kiro CLI **3.0 / `--v3`**（硬性前提：`permissions` 门禁只在 v3 上执行；2.x 会静默忽略） |
| 演练环境 | Node.js 20+、AWS CDK v2、**一个已有 VPC**（本栈不创建 VPC）、AWS 凭证 |

### 4.2 起演练环境

完整说明见 [rehearsal_env/README.md](./rehearsal_env/README.md)，这里只给主干。
**约 $264/月 ≈ $9/天（us-east-1 按需估算），按天用完即销毁。**

```bash
cd rehearsal_env
npm ci
npx cdk bootstrap                          # 账号首次用 CDK 才需要
npx cdk deploy -c vpcId=vpc-xxxxxxxxxxxx   # EKS 创建约 15-20 分钟
```

部署后配置全部脚本化，**本地有 AWS 凭证即可驱动，无需登录跳板机、无需浏览器**。
机制是 `ssm_run.sh` 经 SSM `send-command` 把脚本整段送到跳板机执行并回传输出：

```bash
source ./stack_outputs.sh                 # 从栈 Outputs 导出 BASTION_ID / endpoint / secret 名 / MSK ARN
./ssm_run.sh 'kubectl get nodes'          # 连通性自检

./ssm_run.sh -f bootstrap_db.sh           # 建库/账号/marker 表/binlog 保留 168h
./ssm_run.sh -f bootstrap_pf.sh           # canal-admin port-forward 交给 systemd
./ssm_run.sh -f extract_templates.sh      # 从镜像取 canal/instance properties 模板 + MSK bootstrap
./ssm_run.sh -f bootstrap_admin.sh        # 导入 canal_manager 表 + secret + 部署 canal-admin
./ssm_run.sh -f bootstrap_cluster.sh      # 改默认口令 + 建集群 + 下发主配置
./ssm_run.sh -f bootstrap_server.sh       # 部署 canal-server，确认注册
./ssm_run.sh -f bootstrap_instance.sh     # 建 instance（订阅 reader）
./ssm_run.sh -f fix_instance_cluster.sh   # 补 instance 归属，以 ZK 为判据确认接管
TIMEOUT=900 ./ssm_run.sh -f verify_e2e.sh # 端到端：建 topic → 写 marker → Kafka 消费 → cursor 推进
```

**仓库内不硬编码任何环境标识**：忘了 `source ./stack_outputs.sh` 会在脚本第一行报缺变量，
而不是连到错误的库上。

### 4.3 装 Kiro CLI 与 agent

**两条约束先记住，装错了后面全是坑：**

1. **Kiro CLI 装在哪个用户下，agent 会话就以那个用户运行。** 登录态在该用户的 `~/.kiro`，
   所以 runbook 资产、`env.sh`、口令文件、kubeconfig 都必须对它可读。本项目演练环境统一到
   `ec2-user`（详见 [rehearsal_env/bastion_host.md](./rehearsal_env/bastion_host.md) 第 4 节）。
2. **agent 定义只放全局一份**（`~/.kiro/agents/`）。项目级和全局级同名会让每次启动打印
   `WARNING: Agent conflict ... Using workspace version.`——切割现场不该有这种噪音。
   定义内路径已是绝对路径，全局一份即可从任意目录启动。

先在跳板机上装 Kiro CLI 并登录（按 Kiro CLI 官方安装文档；`kiro-cli login` 需要交互，
无法脚本化），然后：

```bash
# 本地执行，装 agent 到跳板机
./ssm_run.sh -f setup_cli_agent.sh        # 版本闸门(v3) + 口令收敛 + 装到 ~/.kiro/agents/ + validate + deny 冒烟探针
./ssm_run.sh -f smoke_cli_agent.sh        # 只读冒烟（--trust-tools=fs_read，拿不到 shell）
```

`setup_cli_agent.sh` 做五件事：**CLI 版本闸门**（v3 是硬性前提，2.x 且无 `--v3` 开关直接
终止）、把口令收敛到单一权威位置、把 runbook 资产的属主统一到运行身份、按目标机实际路径
重写定义里的 `resources` 与 runbook 根路径并装到全局做 validate、最后跑 **deny 冒烟探针**
把"文档说 v3 执行 permissions"变成本机实测结论——探针不过不许开工。

`smoke_cli_agent.sh` 是零风险验收：只信任 `fs_read`，agent 拿不到 shell，用三个问题验证
"定义能加载 / 提示词生效 / 门禁规则已内化"。**绝不要用 `--trust-all-tools`**——那等于把
agent 的门禁整层拆掉。

在跳板机上启动会话：

```bash
cd ~/canal_cutover_agent
source session_init.sh                    # 加载 env.sh + PATH，打印 pf 服务状态
kiro-cli --v3 chat --agent canal-cutover  # 必须带 v3（原生 3.x 可省 --v3）；--agent 是 chat 子命令的参数
```

### 4.4 跑一次演练

照着 [REHEARSAL_OPERATOR_RUNBOOK.md](./REHEARSAL_OPERATOR_RUNBOOK.md) 走，它给了每阶段
"你说的话 / agent 该做什么 / 你盯什么 / 门禁在哪"的对照表。第一句是：

> 按 runbook 执行 P0 环境断言。

它应当先读 `steering/canal-cutover-runbook.md` 与本 README，再跑脚本。
**若它跳过读 runbook 直接跑脚本，纠正它**——证据驱动的前提是它先加载判据。

之后人只在门禁点批准，加上 switchover 触发和改 Admin 配置两处人工专属动作。
故意乱序试它（比如存档 cursor 之后直接说"启动 instance"），它应当拒绝并指出缺失步骤。

### 4.5 纯人工兜底

agent 不可用时，同一套脚本按编号顺序手工跑：

```bash
cp env.sh.sample env.sh && vi env.sh
bash scripts/00_env_assert.sh
bash scripts/10_preflight_gtid.sh
# ... 依编号顺序，门禁脚本按提示输入 YES
bash scripts/30_verify.sh
```

### 4.6 适配到你的环境

1. **`steering/canal-cutover-runbook.md` 第 1 节的环境事实表必须逐项核对后改写**——
   那是你的环境的事实，agent 拿它当唯一权威知识来源，写错就是错的判据。
2. `env.sh.sample` 复制为 `env.sh` 填全（namespace、pod 名、destination、ZK chroot、
   Admin API、DB 地址、Kafka）。生产与演练环境的 `DESTINATION` 通常不同。
3. 与业务方约定最小权限账号：DB 只读账号 + Admin 操作账号 + 限定 namespace 的 kubectl。
4. `agents/canal-cutover.md` 的禁区清单按你的实际情况调整，改完重新生成 CLI 载体。

---

## 演练报告

`reports/` 里是两轮真实演练的完整报告——判据逐条结果、踩坑清单、agent 行为验收。
这套资产里的每条硬性规则都能在这里找到出处，细节见 [reports/README.md](./reports/README.md)。

- **[2026-07-23](./reports/rehearsal-report-2026-07-23.md)**：故障路径。switchover 先行、
  canal 带旧位点撞 1236 后现场修补。暴露 11 个真实缺陷，其中"绿环境不继承 binlog
  retention""TSDB 需配 `master.timestamp`"两条直接写成了 runbook 硬性要求。
- **[2026-08-15](./reports/rehearsal-report-2026-08-15.md)**：正常路径全程走通，对账零缺失。
  核心产出是三个新坑，第一个尤其值得看：**Blue/Green 的 reader 成员 switchover 失败，
  聚合状态却是 `SWITCHOVER_COMPLETED`**——原 reader 名仍指向被冻结的旧副本，于是并集算在
  了错误的服务器上，而每一步判据形式上都"通过"。

## 已知限制

- `30_verify.sh` 读的是容器 stdout，抓不到 canal 的 instance 级日志，导致 P3 的
  "起点==并集""零 1236""零 RecordTooLarge"三项无法自动判定，需人工核对 instance 日志
  （两轮演练均复现）。
- `51_reconcile.sh` 用 `kubectl logs` 作数据通道，消息量大时会被 kubelet 日志轮转截断，
  产出"全量缺失"的假象。大数据量对账应把消费输出落到 pod 内文件再取回。
- `fix_post_switchover.sh` 第 5 步用 `diff` 直接比对 mysql 原始输出，会被尾随换行误判为
  "回读不一致"（假阴性）。
- Canal 1.1.8 + `caching_sha2_password`：在 RDS MySQL 8.0.42 上实测报文解析必崩
  （[alibaba/canal#5403](https://github.com/alibaba/canal/issues/5403)），在 8.4.10 上未复现。
  演练与切割统一用 `mysql_native_password`——它是唯一在两个版本上都实测可用的选项。
- instance 启停走 Canal Admin REST API；**直接翻转 DB `status` 字段不能启停 cluster 实例**，
  最终判据始终是 ZK 的 `running` 节点。
- 本 agent 只能在**交互式会话**中驱动。无人值守模式下没人应答门禁，请示纪律失去意义。

## 免责与适用范围

- 本仓库是配合技术博客发布的**实践样例**，按现状（as-is）提供，不构成 AWS 官方建议，
  也不是 AWS 支持的产品。
- 脚本会连接数据库、读写 ZooKeeper 节点、修改 Canal 配置。**先在演练环境跑通**，
  并确认你理解每个门禁点的含义，再考虑用于任何生产链路。
- `rehearsal_env/` 会创建 EKS、RDS ×2、MSK、EC2 等**会计费**的资源。演练按天计，
  用完立刻 `cleanup.sh --execute`。费用由你自己承担。栈里有几处刻意的成本取舍
  （EKS API endpoint 公开、MSK 允许 VPC 内 PLAINTEXT、RDS 单 AZ），**生产不可照搬**，
  `rehearsal_env/README.md` 的"安全基线说明"已逐条列出。
- 仓库内的账号 ID、VPC/子网/实例 ID、endpoint、ARN、Secret 名、Blue/Green 部署 ID
  全部是示例占位符；报告里的时间线与 GTID 取值来自已销毁的演练环境。

## 许可与贡献

代码与文档以 [MIT-0](./LICENSE) 许可发布。贡献方式见 [CONTRIBUTING.md](./CONTRIBUTING.md)，
行为准则见 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)。
