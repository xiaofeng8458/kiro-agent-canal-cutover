# 演练报告

两轮真实演练的完整运行报告。它们不是"跑通了"的成功学总结，而是判据逐条结果 +
踩坑清单 + agent 行为验收——这套资产里的每条硬性规则都能在这里找到出处。

| 报告 | 路径 | 一句话 |
|---|---|---|
| 2026-07-23 | [rehearsal-report-2026-07-23.md](./rehearsal-report-2026-07-23.md) | 故障路径：switchover 先行、canal 带旧位点撞 1236 后现场修补。暴露 11 个真实缺陷 |
| 2026-08-15 | [rehearsal-report-2026-08-15.md](./rehearsal-report-2026-08-15.md) | 正常路径全程走通、对账零缺失。产出三个新坑，含"B/G 聚合状态报成功但 reader 成员失败" |

## 关于原始证据

报告引用的原始证据（`runbook_state.md` 执行流水、canal instance 日志、ZooKeeper
快照、cursor 存档、对账中间产物、环境销毁输出）**没有随本仓库公开**：它们逐行都是演练
环境的实际 endpoint、实例标识与内部主机名，脱敏后可读性也会大幅下降。

报告正文里引用的片段都已脱敏。可以这样理解其中的取值：

- 实例 ID、RDS/MSK endpoint、Blue/Green 部署 ID、卷 ID、Secrets Manager 名称、私网 IP
  → **占位符**，非真实值；
- 时间线、GTID 集合、行数与计数、判据结论 → **真实值**，来自已销毁的演练环境。

自己跑一轮演练时，同样格式的证据会由 agent 实时写进 `state/run_YYYYMMDD/runbook_state.md`，
那份流水本身就是报告底稿——这是 runbook 设计里"证据留档"那条规则的直接产物。
