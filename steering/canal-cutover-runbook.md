# Canal 蓝绿切割 Runbook（Agent 知识库）

本文件是驱动切割操作的 agent 的唯一知识来源。Agent 必须遵守「门禁规则」一节，
所有结论必须引用脚本输出作为证据，禁止凭记忆推断环境状态。

## 1. 环境事实（2026-07-21 排障确认，任何不符即中止并报告）

| 项目 | 事实 |
|---|---|
| 部署 | K8s StatefulSet：canal-server × 1 + canal-admin × 2（namespace common-service），官方镜像，app.sh 启动 |
| 配置管理 | Admin 托管（restart.sh local），配置唯一来源为 canal_manager 库，Admin UI/API 是唯一修改入口 |
| 位点存储 | ZooKeeper（default-instance.xml），cursor 路径 /otter/canal/destinations/biz_v2_new/1001/cursor（注意 chroot 前缀） |
| 位点时效 | 内存位点每 1s 刷写 ZK；精确读数须先停 instance |
| 寻位优先级 | 存量位点（ZK cursor）> master.gtid 配置 > 跳最新。存量位点存在时配置被静默忽略 |
| 已知脏数据 | canal_node_server 表中 canal-server-1 为 2023 年陈旧注册行，非真实节点 |
| 保护配置 | canal.auto.reset.latest.pos.mode = false（1236 时卡住重试而非跳位点，保持不变） |
| 表结构库 | mysql-tsdb（meta_history/meta_snapshot），与位点无关，不要碰 |

## 2. 修补公式

```
新位点 = 旧 cursor 的 GTID 集合 ∪ 绿只读副本的 gtid_purged
```

归并方法（任意 MySQL 8.0）：`SELECT GTID_SUBTRACT(CONCAT('<旧集合>', ',', '<gtid_purged>'), '');`
严禁用服务器当前 executed 整体覆盖（会把故障窗口的业务变更静默标记为已消费）。

两条配套硬性要求（2026-07-23 演练实证）：

1. **master.gtid 必须配套 master.timestamp**：TSDB 启用时（instance 模板默认启用），
   `canal.instance.master.timestamp = <存档 cursor 的 timestamp 毫秒值>` 必须同时配置，
   否则 canal 报 `use gtid and TableMeta TSDB should be config timestamp > 0` 拒绝启动。
2. **switchover 完成后第一动作：在新主库重设并验证 binlog retention**
   （`CALL mysql.rds_set_configuration('binlog retention hours', 168)`）。
   retention 是实例本地配置，**绿环境不继承**，默认会快速清 binlog——修补窗口内的
   业务 binlog 一旦被清，并集会把已清区间标记为已消费 = 真实丢数据且无告警。
   并集必须在 retention 确认后用**当时最新的** gtid_purged 计算（purged 是移动靶）。

## 3. 流程与脚本映射

| 阶段 | 脚本 | 类型 | 通过判据 |
|---|---|---|---|
| P0 环境断言 | 00_env_assert.sh | 只读自动 | 全部断言通过 |
| P1 GTID 预检 | 10_preflight_gtid.sh | 只读自动 | 两条 GTID_SUBSET 均为 1，输出并集 |
| —（人工）RDS switchover 触发 | 无 | 禁区 | P0/P1 全绿后由人执行 |
| P2-1 停 instance | 20_stop_instance.sh | 门禁 | Admin API 返回 stopped |
| P2-2 存档 cursor | 21_archive_cursor.sh | 只读自动 | cursor JSON 落盘 state/ |
| P2-3 删 cursor | 22_delete_cursor.sh | 门禁 | stat 返回 Node does not exist |
| P2-4 验配置 | 23_verify_config.sh | 只读自动 | master.gtid 恰出现 1 次、单行、值==并集 |
| P2-5 启动 | 24_start_instance.sh | 门禁 | Admin API 返回 running |
| P3 验证 | 30_verify.sh | 只读自动 | 见验收矩阵 |
| 造数控制 | 40_loadgen.sh start/stop/status | 仅写测试 marker 表，可自主 | 进程运行且 MAX(id) 推进 |
| 端到端验证 | 50_e2e_verify.sh | 仅写一行测试 marker，可自主 | 唯一 tag 到达 Kafka 且 cursor 推进 |
| 数据对账 | 51_reconcile.sh | 只读 + Kafka 消费，可自主 | Kafka id 集合 ⊇ 源表（零缺失；重复属 at-least-once 预期） |

40/50 虽有写操作，但仅限 `MARKER_TABLE` 指定的测试表，纳入可自主执行范围；
对账 FAIL 时先对照本次执行日志中的已知丢失窗口（如 retention 未继承的处置窗口）再定性。

## 3.5 Agent 分工与作用点

脚本负责执行，你（agent）负责认知工作，分五类：

1. **判据比对**：每个脚本跑完，对照本文判据逐条给出 通过/失败 + 证据行 + 下一步建议，
   不允许只贴原始输出让人自己看。
2. **顺序状态机**：你持有完整流程状态。前置步骤未完成（如 cursor 未删就要求启动）时，
   拒绝执行并指出缺失步骤——"停→档→清→验→启"军规由你守护，脚本的局部检查只是兜底。
3. **故障分诊**：P3 出现 1236 时，第一动作是抓日志中 "GTID set sent by the replica"
   的集合与并集比对，按第 6 节判定表定位分支后再给建议。
4. **动态取证**：无脚本覆盖的环节（如升级目标版本上的 Canal 兼容性预检：认证方式、
   语法适配、报文解析三项分别定性）由你用只读命令组合完成并留证。
5. **证据留档**：每阶段实时写 state/ 执行日志；流程结束时该日志即演练/切割报告底稿。

环境参数以 `env.sh` 为准（DESTINATION 等在不同环境不同：生产为 biz_v2_new，
演练环境为 server-0）；本文第 1 节的环境事实表描述的是生产形态，演练环境的差异
（如 zkServers 指向 zookeeper.common-service）以 env.sh 与实际取证为准。

## 4. 门禁规则（Agent 必须遵守）

1. 变更脚本（20/22/24）执行前，先向用户输出：将执行的动作、当前证据摘要、回滚方式，等待用户明确批准后才可运行。
2. 脚本内置的 YES 确认是第二道防线，不能替代第 1 条。
3. 任一脚本判据失败：停止流程，输出失败证据与建议，等待人决策。禁止自行重试变更操作。
4. 禁止执行本 runbook 之外的变更命令（包括但不限于：改 tsdb、动 Kafka topic、删 pod）。
5. 每个阶段完成后将证据追加到 state/ 下的执行日志。

## 5. 验收矩阵（P3，持续观察 ≥ 5 分钟）

| 判据 | 方法 | 通过标准 |
|---|---|---|
| 起点正确 | canal 日志 find start position | gtid == 并集 |
| 无 1236 | 日志 grep | 观察期零命中 |
| 位点推进 | 每 30s 读 cursor | 绿主库 UUID 区间单调增长 |
| 差值收敛 | GTID_SUBTRACT(RO executed, cursor gtid) | 仅剩内部事务区间 |
| Kafka 尺寸 | 日志 grep RecordTooLarge | 零命中 |
| 端到端 | 源库写 marker → Kafka 侧确认 | 秒级到达（人工/半自动） |

## 6. 故障判定表（P3 出现 1236 时）

| 现象 | 结论 | 处置 |
|---|---|---|
| 报错中 sent 集合 ≠ 配置的并集 | 存在未清理的存量位点，或配置未生效（重复 key/换行/未下发） | 停 instance，重走 P2-2 起 |
| sent 集合 == 并集，仍 1236 | 并集不满足服务器要求（purged 又前进了） | 重跑 P1 用最新 gtid_purged 重算并集 |

## 7. 经验条目（2026-07-21 复盘沉淀）

- 1236 报错中 "GTID set sent by the replica" 是 Canal 内存位点的实时快照，是第一取证点。
- properties 值换行即截断；重复 key 后值覆盖前值。配置校验必须回读 DB content 而非相信编辑器。
- ZK 排查三件套：echo srvr（版本，ls -R 需 3.6+）→ echo cons（连接对账）→ 服务端本机 zkCli（不受 chroot 影响）。
- 注册表（canal_node_server）是历史累积，现状以 kubectl get pods 为准。
