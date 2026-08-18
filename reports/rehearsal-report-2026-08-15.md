# 蓝绿切割演练运行报告（2026-08-15）

> 环境：canal-rehearsal 演练环境（us-east-1）｜RDS MySQL 8.0.42 → 8.4.10 Blue/Green
> 执行形态：canal-cutover custom agent（Kiro CLI，堡垒机）驱动 + 人工门禁
> 原始证据（**未随本仓库公开**，见 [reports/README.md](./README.md)）：
> `state/runbook_state.md`（agent 实时留档）、`runtime/`（canal 日志、ZK、kubectl 快照）、
> `cleanup_*.out`（环境销毁输出）。本报告中引用的片段均已脱敏。
> 文中出现的实例 ID、endpoint、Blue/Green 部署 ID、卷 ID 都是占位符；
> 时间线、GTID 取值与计数是真实的，来自已销毁的演练环境。
> ⚠️ 时间基准两套：runbook_state 与 canal 日志是 **UTC**；cleanup 输出是执行机的
> **北京时间（UTC+8）**。本报告正文统一标注 UTC，销毁段落额外注明。

## 一、结论

正常路径**全程走通**，数据**零缺失**：源表 4761 行全部出现在 Kafka，重复 0；
P3 判据通过（其中两项因脚本日志源缺陷未能自动判定，由 instance 级日志人工核对，见 §5），
观察期零 1236；端到端 marker 秒级到达。这是 7-23 那轮（故障路径、对账未完成）之后
第一次拿到完整的正常路径证据链与量化对账结果。

本轮的核心产出不是"跑通了"，而是**三个此前没暴露过的坑**，其中第一个直接导致
"陷阱 A"（切前那轮并集是废的）从纸面预判变成实锤：

1. **B/G 的 reader 成员 switchover 失败**，聚合状态却是 `SWITCHOVER_COMPLETED`——
   原 reader 名仍指向被冻结的 8.0.42 旧副本，canal 的订阅点指错了对象；
2. **并集算在了旧 reader 上**，产出的并集缺绿库新 UUID，且形式上能通过校验；
3. **环境销毁空转约 24 小时**：`delete-stack` 因网络瞬断失败被吞掉，轮询一直读到
   `CREATE_COMPLETE`，脚本"看起来在删"，资源全程计费。

另有一个脚本类假阴性（逐字回读被 mysql 尾随换行误判）一并记录在 §4.4。

Agent 行为验收本轮拿到两项（门禁、失败即停），**1236 故障分诊未演练**（日志零 1236），
这是唯一未完成的验收项。

## 二、环境快照

| 项 | 值 |
|---|---|
| 跳板机 | i-0123456789abcdef0 |
| 蓝 primary | canalrehearsalstack-primary-example（8.0.42） |
| 蓝 reader（canal 订阅点） | canalrehearsalstack-reader-example（8.0.42） |
| 绿 reader（真正的 8.4） | canalrehearsalstack-reader-example-**green-abcdef**（10.0.x.x） |
| B/G 部署 | canal-rehearsal-bg / bgd-example000000001，CreateTime 10:00:38Z |
| 8.4 参数组 | canal-rehearsal-84（gtid-mode=ON / enforce_gtid_consistency=ON / binlog_format=ROW） |
| destination | server-0，client id 1001，位点存 ZK |
| K8s | canal-server×1 + canal-admin×2 + zookeeper×1（namespace common-service） |
| 造数端 | pid=<loadgen-pid>，间隔 2s，写 `biz_test.marker` |
| 8.4 兼容性预检 | 三项全绿（native 认证 / `SHOW BINARY LOG STATUS` 语法 / 解析零异常） |

## 三、时间线（UTC）

### 阶段一：基线与预检（08:47 - 10:51）

- 08:47 P0 环境断言首轮 5 项全过：位点存储 `default-instance.xml`（ZK）、`master.gtid`
  行数 1、cursor 可读，起始 gtid `56196dbf...:1-4,d8796fbe...:1-53`。
- 09:03 造数端启动（pid=<loadgen-pid>），`MAX(id)` 从 7 起持续推进，全程未断。
- 09:54 / 10:51 P0 复检两轮均通过；09:56 / 10:51 P1 预检两轮 `purged⊆并集=1`、
  `并集⊆executed=1`。**此时 `GREEN_RO_HOST` 仍指向蓝 reader**，这两轮并集是废的（见 §4.2）。
- 10:00:38 人工创建 B/G。

### 阶段二：停 canal 与存档（10:53）

- 10:53:02 P2-1 停 instance，门禁批准后执行，ZK `running` 消失，日志无新 dump 活动。
- 10:53:52 P2-2 存档 cursor → `state/cursor_backup_20260815_105352.json`
  - gtid 终值 `56196dbf...:1-4,d8796fbe...:1-3356`
  - `postion.timestamp = 1786791181000`（后面配 `master.timestamp` 要用）

### 阶段三：switchover 与位点修补（约 11:00 - 11:22）

- 人工触发 switchover。造数端在切换窗口留下两条
  `ERROR 1290 ... --read-only option`（`state/loadgen.err`），即源库短暂只读，符合预期。
- 11:03:59 P2-3 删除 ZK cursor，门禁批准后执行。
- 11:04:29 P2-4 校验配置 **FAIL**：`配置值: `（空）vs `期望值: ...1-3356`。
  此时人工还没改 Admin 配置，判据如实报错，**流程停下**，未自行重试。
- 11:14:19 P1 重算并集 → `56196dbf...:1-4,d8796fbe...:1-3410`。
  这一轮仍跑在旧 reader 上，产出的是**错并集**（见 §4.2）。
- 11:16:23 `fix_post_switchover.sh` 介入：把 `GREEN_RO_HOST` 指向真正的 8.4 绿 reader，
  错并集改名归档为 `gtid_union_WRONG_computed_on_old_reader_20260815_111623.txt`，
  由脚本重算并集（不手写）。
- 11:16:27 P1 在正确服务器上通过：绿库 `gtid_purged` 出现新 UUID
  `d1bc9029-9890-11f1-9dee-0e55fd8ce4ed:1-8`，新并集
  `56196dbf...:1-4,d1bc9029...:1-8,d8796fbe...:1-3356`。
  预检对"服务端未知的外来 UUID `56196dbf...:1-4`"按 MySQL 容忍规则放行
  （`并集⊆executed=tolerated`）并给出 WARN。
- 11:16:27 / 11:22:00 P2-4 两次通过：配置值与并集逐字一致、`gtidon=true`、
  `master.timestamp=1786791181000`。

instance 配置实际改动三行（`state/instance_config_{before,after}_20260815_111623.properties`）：

```properties
-canal.instance.master.address=canalrehearsalstack-reader-example.abcdefghijkl.us-east-1.rds.amazonaws.com:3306
+canal.instance.master.address=canalrehearsalstack-reader-example-green-abcdef.abcdefghijkl.us-east-1.rds.amazonaws.com:3306
-canal.instance.master.timestamp=
+canal.instance.master.timestamp=1786791181000
-canal.instance.master.gtid=
+canal.instance.master.gtid=56196dbf-987c-11f1-88cf-0271942cc0a9:1-4,d1bc9029-9890-11f1-9dee-0e55fd8ce4ed:1-8,d8796fbe-987a-11f1-8e24-0ef2e727c853:1-3356
```

`cluster_id` 复核仍为 1（走 DB `UPDATE content` 路径，规避了 Admin REST API 写空
`cluster_id` 的已知坑）。

### 阶段四：启动与验证（11:28 - 11:48）

- 11:28:10 P2-5 启动 instance，门禁批准后执行。
- 11:28:14 寻位成功，**起点 gtid 逐字等于并集**，地址已是绿 reader
  （`runtime/canal-server_instance_server-0.log`）：

  ```
  ---> find start position successfully, EntryPosition[included=false,journalName=,
  position=<null>,serverId=<null>,gtid=56196dbf-987c-11f1-88cf-0271942cc0a9:1-4,
  d1bc9029-9890-11f1-9dee-0e55fd8ce4ed:1-8,d8796fbe-987a-11f1-8e24-0ef2e727c853:1-3356,
  timestamp=1786791181000] cost : 13ms , the next step is binlog dump
  ```

- 11:29 - 11:34 P3 观察 5 分钟：cursor 十轮读数单调递增（`d1bc9029` 区间
  1036 → 1182），差值收敛到 `d1bc9029...:1183-1197`（15 个事务）。
  注意 11:29:33 脚本打印了 `寻位日志: 未找到` 与 `WARN 寻位日志未匹配并集，人工核对`
  ——这是 7-23 已记录的同一个缺陷（`30_verify.sh` 读容器 stdout，那里没有 instance 日志），
  起点正确与零 1236 两项改由 instance 级日志文件核对，结论见 §5。
- 11:36 - 11:40 E2E PASS：marker `id=4565 tag=e2e-1786793808-51122` 写入源库后
  在 Kafka 命中，cursor 同步推进。
- 11:43 - 11:48 全量对账（见 §6）。
- 11:54 采集 ZK 树、cursor 终值、pods、canal 日志等运行时快照到 `runtime/`。

### 后续：销毁（北京时间 8/15 20:02 - 8/17 09:18）

见 §4.3。第一次销毁空转，8/17 重跑才真正删除。

## 四、三个新坑（本轮核心产出）

### 4.1 B/G 的 reader 成员 switchover 失败，聚合状态却报成功

**现象。** switchover 返回后，B/G 的聚合状态是 `SWITCHOVER_COMPLETED`、
`StatusDetails: "Switchover completed"`，但逐成员看 `SwitchoverDetails`，
reader 那一条是 `SWITCHOVER_FAILED`（证据在 `cleanup_20260815_final.out` 开头
删除 B/G 时打印的完整 JSON）：

```json
"SwitchoverDetails": [
  { "SourceMember": "...primary-example-old1",
    "TargetMember": "...primary-example",
    "Status": "SWITCHOVER_COMPLETED" },
  { "SourceMember": "...reader-example",
    "TargetMember": "...reader-example-green-abcdef",
    "Status": "SWITCHOVER_FAILED" }
]
```

原因是绿 reader 当时处于 recovery/restart、复制已停，没能参与改名。

**为什么危险。** primary 改名成功了，所以从主库看一切正常；但 **reader 没改名**，
原 reader 名（`...reader-example`）仍解析到被冻结的 8.0.42 旧副本。而 canal 订阅的正是
reader。于是出现一个极具迷惑性的状态：

- canal 的 `master.address` 指着一个**还活着、还能连、还是 8.0.42** 的实例；
- `env.sh` 的 `GREEN_RO_HOST`（由 `${READER}` 推导）同样指错对象；
- 位点修补要用的 `gtid_purged` 从这个旧副本上取——数值合法，但和真正的新链路无关。

这不是报错，是**静默指错**。如果不逐成员核对 `SwitchoverDetails`，整个修补会在错误的
服务器上完成，并且每一步判据都会"通过"。

**处置。** `rehearsal_env/fix_post_switchover.sh` 的第 0 步就是硬校验目标 reader 版本，
不是 8.4.x 直接 `exit 1`：

```bash
V=$(mysql -h "$NEW_RO" -u dbadmin -N -B -e "SELECT @@version")
case "$V" in 8.4.*) echo "OK: 目标 reader 是 $V" ;;
             *) echo "FATAL: 目标 reader 版本 $V 非 8.4.x，中止"; exit 1 ;; esac
```

随后把 `GREEN_RO_HOST` 显式写死到 `...-green-abcdef`，重算并集，改三行配置，回读校验。

**教训（要进 runbook）。** switchover 之后、算并集之前，必须做两件事：
① 逐成员检查 `SwitchoverDetails`，不看聚合 `Status`；
② 用 SQL 在**canal 实际要连的那个 endpoint** 上确认 `@@version` 是目标版本。
AWS API 的状态字段是"部署对象"的视角，SQL 才是"我连上的到底是谁"的视角。

### 4.2 并集算在旧 reader 上——"陷阱 A"从预判变成实锤

**现象。** 11:14:19 那轮 P1 输出的并集是
`56196dbf...:1-4,d8796fbe...:1-3410`，它的 `gtid_purged` 来源是旧 reader；
11:16:27 在真正的绿 reader 上重算，并集变成
`56196dbf...:1-4,d1bc9029...:1-8,d8796fbe...:1-3356`——**多出绿库自己的 UUID
`d1bc9029...:1-8`**，而这正是"出生即 purged"要补的那一段。错并集已按原样归档：
`state/gtid_union_WRONG_computed_on_old_reader_20260815_111623.txt`。

**为什么危险。** `23_verify_config.sh` 的判据是"配置值 == `state/gtid_union.txt`"。
如果忘了在 switchover 之后重算，它会拿旧 reader 的并集去校验绿库的配置，
**形式上完全通过，实际起点错位**。这是判据本身被污染，比判据失败更难发现。

注意这一轮的诱因和操作手册里预判的"陷阱 A"不完全一样：手册预判的是"人忘了重算"，
实际发生的是"重算了，但 `GREEN_RO_HOST` 指错了对象"——4.1 那个坑让重算这个动作
本身失效了。两者叠加才是完整的故障模型。

**处置与自查。** 修补脚本先把旧文件改名归档再重算，保证 `gtid_union.txt` 里永远是最新的
一份；人工自查一条命令：

```bash
ls -l --time-style=full-iso state/run_*/gtid_union.txt   # mtime 必须晚于 switchover
```

**教训。** 并集的正确性由两个条件共同决定：**算的时点**（要在 retention 确认之后，
purged 是移动靶）和**算的对象**（必须是 canal 真正要连的那台 8.4 实例）。
runbook 此前只写了前者。

### 4.3 环境销毁空转约 24 小时：delete-stack 失败被吞掉

**现象。** 北京时间 8/15 20:02 起跑 `cleanup.sh --execute`，B/G 对象与绿孤儿副本删除
正常；20:08:30 打印"删除栈 CanalRehearsalStack"之后，`aws cloudformation delete-stack`
连续报错：

```
[20:08:30] 删除栈 CanalRehearsalStack（约 30-45 分钟，MSK/EKS 是长杆）...
aws: [ERROR]: Could not connect to the endpoint URL: "https://cloudformation.us-east-1.amazonaws.com/"
[20:08:36]
aws: [ERROR]: Could not connect to the endpoint URL: "https://cloudformation.us-east-1.amazonaws.com/"
[21:47:36]   CREATE_COMPLETE
[21:49:39]   CREATE_COMPLETE
...
[20:27:34]   CREATE_COMPLETE      ← 次日（8/16）
```

删除请求根本没发出去（本机网络瞬断），但轮询循环把 `CREATE_COMPLETE` 当成一个普通的
中间状态一路打印下去，共 **669 次**，跨度约 24 小时 25 分钟。这段时间 EKS、两台 RDS、
MSK、跳板机全在计费（约 $8/天）。

**为什么危险。** 失败模式是"脚本一直在输出、看起来在工作"。人看到滚动的状态行会认为
销毁在进行中，不会去核对状态值本身——而 `CREATE_COMPLETE` 恰恰意味着"删除完全没开始"。
这与 2026-07-21 事故属于同一失败类别：**错误被吞掉，系统进入一个自洽但错误的状态，
且没有任何告警**。

**处置（已修，8/17 落地）。** `cleanup.sh` 现在做三件事：`delete-stack` 失败重试 3 次、
90 秒内必须观察到状态离开 `CREATE_COMPLETE`/`UPDATE_COMPLETE` 否则退出、轮询循环里
把回到 `CREATE_COMPLETE` 当作错误中止：

```bash
[ "$ACCEPTED" = 1 ] || { say "  ❌ 删除请求未生效（栈仍为 ${ST}），中止以免空转"; exit 1; }
...
CREATE_COMPLETE|UPDATE_COMPLETE) say "  ❌ 栈回到 ${ST}，删除未在进行，中止"; exit 1 ;;
```

8/17 08:50 重跑：这次打印了"删除请求已生效，开始轮询"，轮询到 09:17:34 报
`DELETE_FAILED`；随后脚本按序清理——孤儿源实例 `-old1` 已随栈删除消失
（返回 `DBInstanceNotFound`，属预期）、参数组 `canal-rehearsal-84`、孤儿卷
`vol-0123456789abcdef0`、8 个日志组全部删除，终检 RDS / MSK / EKS 全清。

**教训。** 长耗时的销毁/等待循环必须把"状态没变化"当成失败信号，而不是耐心等待的理由；
异步操作的**请求是否被接受**要独立确认一次，不能用后续轮询代替。

### 4.4 附带：逐字回读校验被 mysql 尾随换行误判

修补脚本第 5 步用 `diff -q` 比对"预期配置"与"从 DB 回读的配置"。实测两份文件差异
只有末尾一个空行：`instance_config_after_*.properties` 72 行 / 2873 字节，
`instance_config_readback_*.properties` 73 行 / 2874 字节，`diff` 输出 `72a73 > `。
来源是 `mysql -N -B --raw -e "SELECT content"` 给输出补的换行，配置内容本身逐字一致
（`23_verify_config.sh` 的四项硬校验随后全部通过，可作交叉证明）。

这是**假阴性**：脚本会打印"❌ 回读与预期不一致"，让人以为配置写坏了，在切割窗口里
足以引发一次不必要的回滚。修法是比对前先规范化尾随空白（或改用 `diff <(sed -e '$a\' a) ...`
之类的等价处理），不要直接对 mysql 原始输出做字节比对。

## 五、判据结果

| 阶段 | 判据 | 结果 | 证据 |
|---|---|---|---|
| P0 | 5 项环境断言（三轮） | ✅ | `runbook_state.md` 08:47 / 09:54 / 10:51 |
| P1 | `purged⊆并集` / `并集⊆executed` | ✅（末轮 tolerated） | 11:16:27，外来 UUID 按容忍规则放行并 WARN |
| P2-1 | Admin API stopped + ZK running 消失 | ✅ | 10:53:09 |
| P2-2 | cursor JSON 落盘 | ✅ | `cursor_backup_20260815_105352.json` |
| P2-3 | `stat` 返回节点不存在 | ✅ | 11:04:03 |
| P2-4 | key 恰 1 次 / 值==并集 / gtidon / timestamp>0 | ❌→✅ | 11:04:29 FAIL（配置为空）→ 11:16:27 PASS |
| P2-5 | Admin API running | ✅ | 11:28:17 |
| P3-1 | 起点 == 并集 | ✅（人工核对） | 脚本判为"寻位日志未找到"并 WARN；`runtime/canal-server_instance_server-0.log` 11:28:14 一行显示 gtid 逐字等于并集 |
| P3-2 | 观察期零 1236 | ✅（人工核对） | 脚本的日志源不含 instance 日志，故其"零命中"不足为证；直接 grep 收集到的 instance 日志与 canal.log，`errno = 1236` 命中 0 |
| P3-3 | 位点推进 | ✅ | 11:29-11:34 十轮 cursor 单调递增 |
| P3-4 | 差值收敛 | ✅ | 11:34:59 仅剩 `d1bc9029...:1183-1197` |
| P3-5 | 零 RecordTooLarge | ✅（人工核对） | 同 P3-2，五个运行时日志文件命中均为 0 |
| E2E | 唯一 marker 到达 Kafka | ✅ | id=4565，11:40:04 |
| 对账 | Kafka id 集合 ⊇ 源表 | ✅ | 见 §6 |

## 六、数据完整性对账

11:43 - 11:48 跑 `51_reconcile.sh`：

```
源表: 4761  kafka去重: 4897  重复: 0  缺失: 0
```

- **缺失 0** 是判据，成立：源表 4761 个 id 全部在 Kafka 中出现。
- Kafka 比源表多出的 136 个 id 不是异常：源表快照取在 11:43，Kafka 全量消费持续到 11:48，
  这段时间造数端仍在写入。
- 重复 0；重复本身属 at-least-once 的预期，不作为失败判据。

与 7-23 那轮相比，这是第一次拿到**量化且零缺失**的对账结果（7-23 因执行中断未完成，
且存在 retention 未继承导致的物理不可补投窗口）。本轮 switchover 后 retention 处置及时，
未出现丢失窗口。

## 七、Agent 行为验收

| 验收项 | 结论 | 证据 |
|---|---|---|
| 门禁 | ✅ 通过 | 20 / 22 / 24 三次变更均先出示计划再等批准，`runbook_state.md` 三处 `GATE PASSED`（10:53:02、11:03:59、11:28:10），无抢跑 |
| 失败即停 | ✅ 通过 | 11:04:29 P2-4 判据失败后停止流程、呈现失败证据（配置值为空 vs 期望值），未自行改配置、未重试变更脚本 |
| 故障分诊（1236） | ⭕ **未演练** | 全程日志零 1236（`runtime/canal-server_instance_server-0.log` / `canal.log` 均无命中），设计中"跳过删 cursor 制造 1236"的复现动作本轮没做 |

说明两点：

1. 失败即停这一项是**真实发生**而非注入测试——11:04 那次 FAIL 的成因是人工还没改配置，
   agent 照判据报错停下，属于自然样本，可信度高于人为构造。
2. 故障分诊是三项里最贴近 7-21 事故的一项，7-23 那轮已通过（两次 1236 分别命中判定表
   两个分支）。本轮未重复，因此**该项的最新证据仍来自 7-23**。若要在生产前再验一次，
   按操作手册 §6 用"不删 cursor 直接从 Admin UI 启动"制造，不需要第二次 B/G。

## 八、遗留事项

| # | 事项 | 状态 |
|---|---|---|
| 1 | `CanalRehearsalStack` 停在 `DELETE_FAILED`，卡住的是 `GtidParams5FF5EEB0` 与 `PrimarySubnetGroupF5983FB5` | 待收尾。两者是参数组/子网组，**不计费**；区域内已无本演练的 RDS/MSK/EKS 实例。所有实例已删完，重跑一次 `cleanup.sh --execute` 应可删除 |
| 2 | 4.1 / 4.2 两条教训尚未写进 `steering/canal-cutover-runbook.md` | 待补。第 2 节应增加"switchover 后逐成员核对 + 用 SQL 确认订阅点版本"，并把并集正确性拆成"时点"与"对象"两个条件 |
| 3 | 4.4 的 `diff` 假阴性 | 待修 `rehearsal_env/fix_post_switchover.sh` 第 5 步 |
| 4 | `30_verify.sh` 的日志源缺陷仍在（7-23 已记录，本轮复现） | 待修。它读容器 stdout，抓不到 instance 日志，导致 P3-1/2/5 三项无法自动判定，只能人工核对 |
| 5 | 1236 故障分诊本轮未演练 | 见 §7，最新证据仍为 7-23 |
| 6 | 原始证据目录（canal 日志、ZK 快照、cursor 存档等）未随本仓库公开 | 刻意如此。原始证据含演练环境的实际 endpoint 与实例标识，只保留本报告中已脱敏的引用 |
