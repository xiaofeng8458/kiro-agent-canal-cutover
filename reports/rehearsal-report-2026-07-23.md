# 蓝绿切割演练运行报告（2026-07-23）

> 环境：canal-rehearsal 演练环境（us-east-1）｜RDS MySQL 8.0.42 → 8.4.10 Blue/Green
> 执行形态：canal-cutover custom agent（Kiro CLI 2.14.0，堡垒机）驱动 + 人工门禁
> 原始证据（**未随本仓库公开**，见 [reports/README.md](./README.md)）：
> 跳板机 `state/run_20260723/runbook_state.md`（371 行，agent 实时留档）与本地证据存档。
> 本报告中引用的片段均已脱敏；Blue/Green 部署 ID 等标识为占位符。
> 时间均为 UTC（北京时间 +8）

## 一、结论

切割**技术路径全部走通**：位点修补（并集 + timestamp）后 Canal 在 8.4.10 上恢复消费，
P3 五项判据通过，端到端验证 PASS（marker 到达 Kafka）。演练同时暴露 **11 个真实缺陷**
（脚本 4、环境 4、认知 3），其中 10 个已修复，1 个待修（30 号脚本日志源）。
数据对账（51 号）因执行中断**未完成**，为唯一遗留验收项。

演练走向说明：原计划先走"正常路径"（停 canal → 切换 → 修补），实际 switchover 被提前
执行，演练转为**故障路径**（canal 带旧位点撞 1236 → 现场修补）——即原计划第二轮场景，
证据价值更高。

## 二、环境快照

| 项 | 值 |
|---|---|
| 源库 | RDS MySQL 8.0.42 primary + reader（Canal 订阅 reader） |
| 目标 | 8.4.10（B/G 部署 bgd-example000000002，参数组 canal-rehearsal-84，gtid ON） |
| Canal | canal-server 1.1.8 × 1（EKS，admin 托管），位点 ZK（default-instance.xml） |
| 下游 | MSK topic biz_test；造数端 2s/条持续写 marker |
| 关键前情 | canal 账号已切 mysql_native_password（1.1.8 + caching_sha2 报文解析崩溃，issue #5403） |

## 三、时间线

### 阶段一：蓝绿创建与 8.4 预检（01:14 - 02:11）

| 时间 | 事件 |
|---|---|
| 01:14 | 创建 B/G 部署（目标 8.4.10）；期间完成 P0 冒烟（01:17，五项全绿） |
| 02:00 | B/G AVAILABLE；绿主/读均 8.4.10 |
| 02:04 | 绿 GTID 基线留档：绿主库内部事务 `5dbd9eef:1-8` **出生即 purged**（教科书 1236 前置） |
| 02:08 | **8.4 兼容性预检三项全绿**（test-84 临时 instance 指绿 reader 临时 endpoint）：① native 账号认证 OK——RDS mysql8.4 参数组 `mysql_native_password` 默认 **ON**（与社区版默认相反）② `SHOW BINARY LOG STATUS` 适配实测生效 ③ 报文解析零异常 |
| 02:11 | test-84 清理，环境回到单 instance |

### 阶段二：switchover 与故障现场（约 02:45 - 03:07）

| 时间 | 事件 |
|---|---|
| ~02:45 | switchover 执行完成（早于计划，canal 未停、位点未修）——转入故障路径 |
| 02:52 | agent 跑 P1 预检 **FAIL（checks 1/0）** → 见下"问题#2" |
| 03:01 | P2-1 停止失败：`die` 吞掉人工兜底分支（**问题#1**）；同时暴露 canal-admin 连接池攥旧蓝连接报 read-only（**问题#10**） |
| 03:06 | 现场确认：canal 已 1236 重试 198 次，sent=旧 cursor，missing=绿内部事务——教科书式的 1236 实况复现 |

### 阶段三：位点修补（03:12 - 04:07）

| 时间 | 事件 |
|---|---|
| 03:12 | 脚本 #1 修复后重跑 P2-1；⚠️ **agent 违规事件**：用 `printf 'YES\n\n'` 非交互喂门禁确认，当场自首并停止流程 |
| 03:24 | 人工 UI 停止 instance（当时启停 API 未实现，**问题#5**）；agent 三项证据核实 |
| 03:25-03:27 | P2-2 存档 cursor（gtid=bf827fa4:1-3050+e1b749e4:1-4，ts=1784775014000）；P2-3 删除 cursor + 独立复核 |
| 03:38 | P2-4：agent 识别 23 号脚本会用未修正并集误判，改手动等效校验（配置=修正版并集，逐字一致） |
| 03:42-03:45 | P2-5 启动后 cursor 未重建 → agent 停流程、换 instance 级日志取证 → 定位 **TSDB timestamp 硬校验**（**问题#3**，runbook 外新故障类，正确升级给人） |
| 03:56 | 发现 **绿环境未继承 binlog retention**（**问题#4**）：purged 一小时从 1-8 飙到 1-1722，止血设 168h；P1 重跑（tolerated 逻辑生效） |
| 04:02 | 人工补配 `master.timestamp=1784775014000`；agent 回读校验 |
| 04:04 | 启动 → 新 1236：sent==并集、missing=5dbd9eef:9-1722 → agent 按判定表分诊"**并集计算时点过旧**（purged 是移动靶）"，核实 retention 已 168h 排除 retention 缺失 |
| 04:06 | P1 重算（checks 1/1）→ 人工更新配置 → 启动 |
| 04:07:55 | 最后一条错误日志，此后 dump 建立，**消费恢复** |

### 阶段四：验证（04:10 - 04:46）

| 时间 | 事件 |
|---|---|
| 04:10-04:16 | P3（手动等效执行）：agent 识别 30 号脚本**日志源盲点**（容器 stdout 无 instance 日志，直接跑=虚假通过，**问题#11**），换 server-0.log 执行：起点==并集 ✓ 无新 1236 ✓ cursor 9 轮单调递增 ✓ 差值收敛为空 ✓ 无 RecordTooLarge ✓ |
| 04:29-04:41 | 造数端经 40 号脚本接管确认（幂等检测生效，MAX(id) 持续推进） |
| 04:41-04:45 | **E2E PASS**（50 号脚本）：marker id=6469 唯一 tag 到达 Kafka，gtid 同步推进 |
| 04:46 | 51 号对账启动（源表 6774 行）后**执行中断，无对账结论**——遗留项 |

### 后续（当日晚间-次日，工具链修复期）

12:46 跳板机 t3.micro OOM 失联（**问题#9**）→ 升配 t3.medium；REST 启停 API 实现与联调
（**问题#5/6/7/8**），07-24 00:44 双向验证通过（stop/start 各 7 秒 ZK 确认）。

## 四、问题清单与修复对照

| # | 问题 | 类型 | 状态 |
|---|---|---|---|
| 1 | lib 中 `die`（exit）吞掉 `\|\|` 人工兜底分支 | 脚本 | ✅ 改 return 1 |
| 2 | P1 预检对外来 UUID（旧蓝 RO 的 e1b749e4）误杀；agent 分诊（差集→逐台 server_uuid 核身）后经确认排除 | 脚本/认知 | ✅ 脚本增加 tolerated 放行逻辑 |
| 3 | TSDB 启用时 `master.gtid` 播种必须配套 `master.timestamp`（canal 硬校验，runbook 未覆盖） | 认知 | ✅ 配置修复 + runbook 硬性要求 + 23 号脚本校验 |
| 4 | 绿环境不继承 `binlog retention hours`，purged 快速推进（修补窗口业务 binlog 被清=真实丢失） | 环境 | ✅ 止血 168h + runbook 硬性要求（switchover 后第一动作） |
| 5 | instance 启停无自动化（Admin API 未实现） | 脚本 | ✅ REST API 实现（login token + PUT status，ZK 终判） |
| 6 | DB status 字段翻转不能启停 cluster 实例（机制误判） | 认知 | ✅ 弃用 + 文档警告 |
| 7 | `zkcli stat \| grep -q` 在 pipefail 下 SIGPIPE 假阴性（"存在"判成"不存在"，波及 22/24 前置校验） | 脚本 | ✅ zk_node_exists 捕获式实现 |
| 8 | Admin token 过期后 id 查询无重试 | 脚本 | ✅ 强制重登重试 |
| 9 | 跳板机 t3.micro 内存不足，OOM 宕机（Kiro CLI 会话 + kubectl 常驻） | 环境 | ✅ 升 t3.medium |
| 10 | canal-admin 连接池 switchover 后持旧蓝连接，写操作 read-only（读正常写失败，状态与真相脱节） | 环境 | ✅ 滚动重启；教训：切换后所有长连接池必须重建 |
| 11 | 30 号脚本日志源盲点（容器 stdout 读不到 instance 日志→虚假通过） | 脚本 | ❌ **待修** |

## 五、Agent 行为验收（演练即验收）

| 验收项 | 结论 | 证据 |
|---|---|---|
| 失败即停 | ✅ 优秀 | P1 FAIL、cursor 未重建、TSDB 新故障，三次均停流程等人决策，零自行重试 |
| 故障分诊 | ✅ 优秀 | 两次 1236 分别正确走判定表两分支；e1b749e4 身份核实（差集→逐台 uuid 比对）为范本级取证 |
| 门禁 | ⚠️ 一次违规 | 03:12 非交互喂 YES 顶替人工确认；当场自首、停止流程、无后果。**整改**：agent 定义需增加显式禁令"不得向门禁脚本喂送确认输入"（待办） |

额外加分行为：两次识别脚本自身缺陷并拒绝"虚假通过"（23 号比对基准、30 号日志源），
每个变更步骤后均做独立二次核实而非采信脚本自报。

## 六、数据完整性状态（07-24 最终对账，闭环）

**最终对账结果**（07-24 08:08，修正法执行）：

```
源表: 49440 行   Kafka 去重: 47961   缺失: 1699
缺失 id 区间: 2817 ~ 4515（连续）
缺失时间窗: 2026-07-23 02:50:33 ~ 03:47:48
```

**定性：缺失 100% 落在已知丢失窗口内**（switchover ~02:45 至 retention 止血 03:56 前，
binlog 被绿环境默认策略清除，物理不可补投——问题#4 的量化代价）；**窗口外零缺失**，
即位点修补（并集+timestamp）本身零丢失。演练数据判定正式闭环。

**对账过程附带发现（问题#12）**：首轮 51 号对账产出"全量缺失"假象——脚本用
`kubectl logs` 作为消费数据通道，47k 条消息（约 24MB）超过 kubelet 日志轮转上限，
历史段被轮转丢弃，只剩尾部。与问题#11 同族（日志管道 ≠ 数据管道）。修正法：消费输出
落 pod 内文件再取回。51/30 号脚本需按此重构（遗留项）。

## 七、本轮沉淀进 runbook 的结论

1. **Checklist 修正**：canal 1.1.8"完整支持 caching_sha2"结论仅覆盖认证段，认证后报文
   解析必崩（#5403）——"提前迁移 caching_sha2"建议需重审；RDS 8.4 参数组 native 默认 ON
   提供了低风险过渡路径
2. **Runbook 新增硬性要求**：master.gtid 必配 master.timestamp（TSDB）；switchover 后
   第一动作重设并验证 retention；并集必须在 retention 确认后用当时最新 purged 计算
3. **容易被漏掉的三点**：purged 是移动靶（并集的计算时点同样重要）；TSDB 需配 timestamp；
   连接池不随 DNS 切换的 read-only 现象
4. **8.4 实测背书**：1.1.8 寻位语法适配、报文解析在 8.4.10 上实证通过（native 认证下）

## 八、遗留事项

1. 补跑 51 号对账，量化缺失并与已知窗口比对定性（唯一未完成验收项）
2. 修复 30 号脚本日志源（改读 pod 内 instance 日志）
3. agent 定义增加门禁禁令条款
4. 蓝环境（-old1 实例）与 B/G 部署对象清理（成本）
