# Canal 蓝绿切割 Runbook Agent

RDS for MySQL 8.0 → 8.4 蓝绿切换（Blue/Green Deployment）中，**Canal CDC 位点修补与验证**的
一整套可执行资产：agent 定义 + 知识库 runbook + 编号脚本 + 一套可一键起停的 AWS 演练环境。

设计目标：**证据驱动、门禁保护、与 agent 工具解耦**——CLI agent（推荐）、IDE agent、纯人工
三种驱动方式执行的是同一套脚本，同一套判据。

> 📝 配套博客：_待补链接（博客发布后填入）_
>
> **这个仓库是配合博客发布的实践样例，不是 AWS 官方产品或托管服务。**
> 里面的脚本会连你的数据库、改 Canal 配置、创建会计费的 AWS 资源。请先读完
> [免责与适用范围](#免责与适用范围)，并**务必先在演练环境跑通**再考虑用于生产。
> 仓库内出现的所有账号 ID、VPC/实例 ID、endpoint、ARN 均为示例占位符，非真实环境。

## 为什么需要它

RDS Blue/Green switchover 之后，绿环境是**新的 binlog 家系**：它有自己的 server UUID，
而这段 UUID 的事务在绿库"出生即 purged"。Canal 带着旧位点去连新主库，命中的是
`errno = 1236`（`Cannot replicate because the source purged required binary logs`）。

修补动作本身只有一行公式，难的是**顺序**与**判据**：

```
新位点 = 旧 cursor 的 GTID 集合 ∪ 绿只读副本的 gtid_purged
```

存量位点（ZooKeeper 里的 cursor 节点）优先级**高于** `canal.instance.master.gtid` 配置。
顺序颠倒一步，配置就被静默忽略——没有报错，只有几个小时后才发现的数据缺口。
所以这套资产的重点不是"跑脚本"，而是把顺序、判据、门禁、取证固化下来，交给一个
被约束住的 agent 执行，人只在关键点按门禁。

## 目录结构

```
.
├── README.md                          # 本文件
├── REHEARSAL_OPERATOR_RUNBOOK.md      # 人看的操作手册（演练现场照着走）
├── env.sh.sample                      # 环境变量模板，复制为 env.sh 后填写（env.sh 已 gitignore）
├── steering/
│   └── canal-cutover-runbook.md       # Agent 知识库：环境事实 + 流程 + 判据 + 门禁规则
├── scripts/
│   ├── lib/common.sh                  # 公共函数（环境加载、日志、确认门禁、Admin REST 封装）
│   ├── 00_env_assert.sh               # P0 环境断言（只读，自动）
│   ├── 10_preflight_gtid.sh           # P1 GTID 预检 + 并集生成（只读，自动）
│   ├── 20_stop_instance.sh            # P2 停 instance            [门禁]
│   ├── 21_archive_cursor.sh           # P2 存档 cursor（只读）
│   ├── 22_delete_cursor.sh            # P2 删除 cursor 节点        [门禁]
│   ├── 23_verify_config.sh            # P2 校验 master.gtid 配置（只读）
│   ├── 24_start_instance.sh           # P2 启动 instance          [门禁]
│   ├── 30_verify.sh                   # P3 验证循环（只读，自动）
│   ├── 40_loadgen.sh                  # 造数端（仅写测试 marker 表）
│   ├── 50_e2e_verify.sh               # 端到端验证（marker → Kafka）
│   └── 51_reconcile.sh                # 数据完整性对账（源表 id vs Kafka id）
├── agents/
│   ├── canal-cutover.md               # 唯一真源：契约正文 + permissions 策略（Kiro IDE 执行）
│   ├── canal-cutover.cli.json         # Kiro CLI 载体，由下面的生成器产出，勿手改
│   └── gen_cli_json.sh                # 从 md 生成 CLI 载体（消除两个载体手动同步）
├── reports/                           # 两轮真实演练的运行报告（判据结果、踩坑、行为验收）
├── state/                             # 运行产物：证据存档 + 执行日志（自动创建，内容 gitignore）
└── rehearsal_env/                     # AWS 演练环境 CDK（EKS + RDS 主从 + MSK + 跳板机），见其 README
```

## 前置条件

| 项 | 要求 |
|---|---|
| Canal | 1.1.8（Admin 托管模式，位点存 ZooKeeper / `default-instance.xml`） |
| 数据库 | RDS for MySQL，GTID 模式开启（`gtid-mode=ON` / `enforce_gtid_consistency=ON` / `binlog_format=ROW`） |
| 运行环境 | bash 4+、`mysql` 客户端、`kubectl`、`jq`、`curl`、AWS CLI v2 |
| Agent（可选） | Kiro IDE 1.0.x 或 Kiro CLI 2.18.x —— **门禁语义随版本变化，见下表** |
| 演练环境（可选） | Node.js 20+、AWS CDK v2、一个已有 VPC（本栈不创建 VPC） |

## 使用方式

### 方式一：Kiro custom agent 驱动（推荐主路径，人只守门禁）

Agent 定义的唯一真源是 `agents/canal-cutover.md`：YAML frontmatter 声明工具面与
`permissions` 策略规则，正文是行为契约（系统提示词）。CLI 载体由
`bash agents/gen_cli_json.sh` 从这份 md 生成，**不要手改生成物**。

IDE 侧把 `agents/canal-cutover.md` 复制到工作区 `.kiro/agents/` 即可在 agent 选择器中看到它。

#### ⚠️ 门禁生效有版本前提（2026-08-17 实测，勿想当然）

| 运行面 | 实测版本 | `permissions` 是否生效 | 门禁实际由什么保证 |
|---|---|---|---|
| Kiro IDE | 1.0.309 | ✅ 强制 | 声明式策略（allow/ask/deny）+ 契约 + 脚本 YES |
| Kiro CLI | 2.18.1 | ❌ **静默忽略，不告警** | `allowedTools` 白名单（仅 fs_read 免批，其余逐条 y/t）+ 契约 + 脚本 YES |

CLI 侧实测三条：① `agent validate --path xxx.md` 报
`Json supplied ... is invalid`，即 2.18.1 不认 Markdown；② 给探针 agent 配
`deny shell: "echo *"`，命令照样执行成功，说明 `permissions` 未被执行；
③ `agent validate` 对完全瞎编的字段也返回退出码 0，**"校验通过"不等于"规则生效"**。

因此 `canal-cutover.cli.json` 刻意**不含** `permissions` 字段——写进去只会制造
"以为配了门禁"的假象，这与本项目复盘里那类"配置被静默忽略"的事故同属一个失败类别。
CLI 会话里契约就是第一道防线，禁区命令没有机器拦截。

IDE 侧实测：deny 命中时命令根本不执行，提示点名规则与来源作用域；`&&` 复合命令
按子命令判定，任一子命令命中 deny 则整条被拒（不存在"前半段已经跑了"），
所以拼接命令绕门禁这条路在 IDE 侧是堵死的。

**换 Kiro 版本前，先把上面三条重测一遍再改配置。** 不要假设新版本更严格。

- **IDE**：把 `agents/canal-cutover.md` 放进工作区 `.kiro/agents/`，agent 选择器中选 canal-cutover
- **CLI（堡垒机）**：使用 `agents/canal-cutover.cli.json`。
  部署与校验已脚本化：`rehearsal_env/ssm_run.sh -f rehearsal_env/setup_cli_agent.sh`，
  它会按目标机实际路径重写 `resources` 与提示词里的 runbook 根路径，装到
  **`~/.kiro/agents/canal-cutover.json`（只放全局一份）**并做 validate。
  权限映射：fs_read 免批，execute_bash 每条命令提示 y/t（按 t 信任本会话）。
  启动：`kiro-cli-chat chat --agent canal-cutover`（注意 `--agent` 是 chat 子命令的参数）；
  配置校验：`kiro-cli-chat agent validate --path ~/.kiro/agents/canal-cutover.json`

  ⚠️ 三条实测约束：
  1. **别同时放项目级和全局级**——同名 agent 会让每次启动打印
     `WARNING: Agent conflict ... Using workspace version.`。定义内路径已是绝对路径，
     全局一份即可从任意目录启动。
  2. **运行身份要与 Kiro CLI 的安装/登录身份一致**。CLI 装在哪个用户下、登录态就在那个
     用户的 `~/.kiro`，agent 会话必然以该用户运行——runbook 资产、`env.sh`、口令文件、
     kubeconfig 都必须对它可读（演练环境是 `ec2-user`，详见
     `rehearsal_env/bastion_host.md` 第 4 节）。
  3. 非交互冒烟用 `--no-interactive --trust-tools=fs_read`（只给读、拿不到 shell），
     可零风险验证定义加载与门禁规则内化；**绝不用 `--trust-all-tools`**。

指令示例："按 runbook 执行 P0 预检"。之后人只在门禁点批准，其余由 agent 完成。

**Agent 承担的五类工作**（脚本只产出输出，以下认知工作由 agent 完成）：

1. **判据比对**：跑脚本 → 解析输出 → 对照 runbook 判据逐条打勾 → 结论+证据行+下一步
2. **顺序状态机**：守护"停→档→清→验→启"军规，前置步骤未完成时拒绝执行后续步骤
3. **故障分诊**：出现 1236 时第一动作抓 "GTID set sent by the replica" 与并集比对，
   按故障判定表定位分支（存量位点残留 vs 并集过期）
4. **动态取证**：脚本未覆盖的环节（如升级目标版本兼容性预检）用只读命令自由组合取证
5. **证据留档**：每阶段证据实时进 `state/` 执行日志，收尾即报告底稿

**切割中的分工**：

| 步骤 | Agent | 人 |
|---|---|---|
| P0/P1 预检 | 执行+判据结论 | 看结论 |
| 停 instance（20） | 出示计划/证据/回滚，等批准后执行 | 批准 |
| 存档 cursor（21） | 自主执行 | — |
| **RDS switchover** | 提示"预检全绿可切换"，**到此为止** | **人工触发** |
| 并集+预检（10） | 自主执行 | — |
| 删 cursor（22） | 出示计划，等批准 | 批准 |
| 配置校验（23） | 回读 DB 逐字比对 | 改配置（或授权 agent 走 Admin API） |
| 启动（24） | 前置硬校验+等批准 | 批准 |
| P3 验证（30） | 持续监测+故障分诊 | 看报告 |

**三层可用性**（按现场条件降级）：堡垒机 Kiro CLI（需登录认证）→
本地 IDE agent 经 SSM send-command 远程执行（已实测可行）→ 纯人工跑脚本（兜底）。
Agent 行为契约写死在定义中：只读脚本（00/10/21/23/30）自主执行；变更脚本（20/22/24）
先请示；判据失败即停、禁止自行重试；禁止 `scripts/` 之外的变更命令。脚本内置的 `YES`
门禁独立于 agent 存在，两层防线不互相替代。

⚠️ **Agent 必须先在演练环境完整跑通一次切割流程（含门禁与故障分诊行为验证），
才允许出现在生产切割中**——演练同时是 agent 的验收测试。

### 方式二：纯人工（兜底路径）

```bash
cp env.sh.sample env.sh && vi env.sh      # 填写环境参数
bash scripts/00_env_assert.sh             # 逐个编号顺序执行
bash scripts/10_preflight_gtid.sh
# ... 依编号顺序，门禁脚本按提示确认
bash scripts/30_verify.sh
```

## 安全模型

| 级别 | 操作 | 行为 |
|---|---|---|
| 只读 | 00 / 10 / 21 / 23 / 30 | 自动执行，结果与证据写入 `state/` |
| 仅写测试表 | 40 / 50 / 51 | 自动执行，写操作限于 `MARKER_TABLE` 指定的测试表 |
| 变更 | 20 / 22 / 24 | 执行前打印操作计划与回滚方式，要求逐字输入 `YES` 确认 |
| 禁区 | RDS switchover 触发、演练环境销毁、异常中止决策 | 不在脚本范围内，由人决策执行 |

口令不落仓库：`env.sh` 已 gitignore，DB 密码走 `MYSQL_PWD` 环境变量或外部口令文件；
演练环境的 dbadmin 口令由 Secrets Manager 托管，其余口令在跳板机本地生成。
agent 定义里对 `*.pem` / `*.key` / `.env` / 口令文件是 `fs_read: deny`——脚本能加载，
agent 自己读不到明文。

## 顺序军规（违反即事故）

```
停实例 → 存档 → 清存量位点 → 验配置 → 启动 → 验收
```

存量位点（ZK cursor）优先级高于 `master.gtid` 配置。顺序颠倒 = 配置被静默忽略。

两条配套硬性要求（演练实证，细节见 `steering/canal-cutover-runbook.md` 第 2 节）：

1. **`master.gtid` 必须配套 `master.timestamp`**：TSDB 启用时（instance 模板默认启用），
   缺 timestamp 会让 canal 直接拒绝启动。
2. **switchover 完成后第一动作：在新主库重设并验证 binlog retention**。retention 是实例
   本地配置，**绿环境不继承**——修补窗口内的业务 binlog 一旦被清，并集会把已清区间
   标记为已消费 = 真实丢数据且无告警。并集必须在 retention 确认后用**当时最新的**
   `gtid_purged` 计算（purged 是移动靶）。

## 演练环境

`rehearsal_env/` 是一套复刻生产形态的 CDK 栈（EKS 上的 ZK + canal-admin×2 + canal-server，
RDS 主从，MSK，SSM 接入的跳板机），**约 $264/月 ≈ $9/天（us-east-1 按需估算），按天用完即销毁**。
部署、部署后配置、演练流程、清理见 [rehearsal_env/README.md](./rehearsal_env/README.md)；
跳板机完整配置档案见 [rehearsal_env/bastion_host.md](./rehearsal_env/bastion_host.md)。

**本栈不创建 VPC**，必须用 `-c vpcId=vpc-xxx` 指定现有 VPC。栈里有几处刻意的成本取舍
（EKS API endpoint 公开、MSK 允许 VPC 内 PLAINTEXT、RDS 单 AZ），**生产不可照搬**，
`rehearsal_env/README.md` 的「安全基线说明」已逐条列出。

`rehearsal_env/` 下的脚本不硬编码任何环境标识：本地先 `source ./stack_outputs.sh`
从栈 Outputs 导出 `BASTION_ID` / endpoint / secret 名 / MSK ARN，`ssm_run.sh` 再透传到跳板机。

## 演练报告

`reports/` 里是两轮真实演练的完整报告，包含判据逐条结果、踩坑清单与 agent 行为验收：

- [2026-07-23](./reports/rehearsal-report-2026-07-23.md)：故障路径（switchover 先行、canal 撞 1236
  后现场修补）。暴露 11 个真实缺陷，其中"绿环境不继承 binlog retention""TSDB 需配
  master.timestamp"两条直接写进了 runbook 硬性要求。
- [2026-08-15](./reports/rehearsal-report-2026-08-15.md)：正常路径全程走通，对账零缺失。
  核心产出是三个新坑，第一个尤其值得看：**B/G 的 reader 成员 switchover 失败，
  聚合状态却是 `SWITCHOVER_COMPLETED`**——原 reader 名仍指向被冻结的旧副本，
  于是并集算在了错误的服务器上，而每一步判据形式上都"通过"。

## 适配到你的环境

1. `steering/canal-cutover-runbook.md` 第 1 节的「环境事实」表是**你的环境的**事实，
   必须逐项核对后改写。agent 会拿它当唯一权威知识来源，写错就是错的判据。
2. `env.sh.sample` 复制为 `env.sh` 并填全（namespace、pod 名、destination、ZK chroot、
   Admin API、DB 地址、Kafka）。生产与演练环境的 `DESTINATION` 通常不同。
3. 与业务方约定最小权限账号：DB 只读账号 + Admin 操作账号 + 限定 namespace 的 kubectl。
4. `agents/canal-cutover.md` 的 `permissions` 规则按你的目录布局与禁区清单调整，
   改完在你的 Kiro 版本上**实测 deny 是否真的拦得住**。

## 已知限制

- `30_verify.sh` 读的是容器 stdout，抓不到 canal 的 instance 级日志，导致 P3 的
  「起点==并集」「零 1236」「零 RecordTooLarge」三项无法自动判定，需人工核对
  instance 日志（两轮演练均复现，见报告）。
- `51_reconcile.sh` 用 `kubectl logs` 作数据通道，消息量大时会被 kubelet 日志轮转截断，
  产出"全量缺失"假象。大数据量对账应把消费输出落到 pod 内文件再取回。
- `fix_post_switchover.sh` 第 5 步用 `diff` 直接比对 mysql 原始输出，会被尾随换行误判为
  "回读不一致"（假阴性）。
- Canal 1.1.8 + `caching_sha2_password`：在 RDS MySQL 8.0.42 上实测报文解析必崩
  （[alibaba/canal#5403](https://github.com/alibaba/canal/issues/5403)），在 8.4.10 上未复现。
  演练与切割统一用 `mysql_native_password`——它是唯一在两个版本上都实测可用的选项。
- instance 启停走 Canal Admin REST API；**直接翻转 DB `status` 字段不能启停 cluster 实例**，
  最终判据始终是 ZK 的 `running` 节点。

## 免责与适用范围

- 本仓库是配合技术博客发布的**实践样例**，按现状（as-is）提供，不构成 AWS 官方建议，
  也不是 AWS 支持的产品。
- 脚本会连接数据库、读写 ZooKeeper 节点、修改 Canal 配置。**先在演练环境跑通**，
  并确认你理解每个门禁点的含义，再考虑用于任何生产链路。
- `rehearsal_env/` 会创建 EKS、RDS ×2、MSK、EC2 等**会计费**的资源。演练按天计，
  用完立刻 `cleanup.sh --execute`。费用由你自己承担。
- 仓库内的账号 ID、VPC/子网/实例 ID、endpoint、ARN、Secret 名、Blue/Green 部署 ID
  全部是示例占位符；报告里的时间线与 GTID 取值来自已销毁的演练环境。

## 许可与贡献

代码与文档以 [MIT-0](./LICENSE) 许可发布。贡献方式见 [CONTRIBUTING.md](./CONTRIBUTING.md)，
行为准则见 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)。
