# 贡献指南

欢迎 issue 与 pull request。这个仓库是配合博客发布的实践样例，维护节奏不高，
但**任何"我在自己环境里跑出了不同结果"的反馈都特别有价值**——这套资产的全部结论
都来自实测，反例比赞同更有用。

## 提 issue 前

先看 README 的「已知限制」，那里列了我们自己知道但还没修的问题。

报告缺陷时请带上：

- 你的 Canal 版本、MySQL 版本（含小版本号）、Kiro CLI 版本
- 复现步骤与**脚本的实际输出**（判据是哪一条不满足）
- 你期望的行为

**不要在 issue、PR 或截图里贴这些内容**：AWS 账号 ID、ARN、VPC/子网/实例 ID、
RDS/MSK endpoint、Secrets Manager 名称、口令、token、私网 IP、内部主机名、业务库表名。
需要贴日志时先脱敏（本仓库里的所有此类标识都是占位符，可以照那个形态替换）。

## 提 PR 前

1. 讨论优先：改动涉及门禁语义、脚本安全分级、runbook 判据时，先开 issue 说明动机。
   这些地方的每一条规则背后都有一次真实故障，改之前要先知道它挡的是什么。
2. Shell 脚本请通过 `bash -n`（语法）与 `shellcheck`（有条件的话）。
3. 涉及 agent 定义的改动：`agents/canal-cutover.md` 是唯一真源，改完必须跑
   `bash agents/gen_cli_json.sh` 重新生成 CLI 载体，两个文件一起提交。
   **不要手改 `agents/canal-cutover.cli.json`。**
4. 如果你的改动依赖某个 Kiro 版本的行为，请在 PR 里写清你实测的版本号与观察到的现象。
   本项目的验证运行面是 Kiro CLI 2.18.x；换版本时门禁语义可能变，别靠推断。
5. 不要提交 `env.sh`、`state/` 下的运行产物、`cdk.out/`、`cdk.context.json`、任何日志文件。
   `.gitignore` 已覆盖，但请自己 `git status` 复核一遍。

## 许可

提交贡献即表示你同意以本仓库的 [MIT-0](./LICENSE) 许可发布你的贡献。

## 安全问题

如果你发现的是安全缺陷（例如某条门禁规则可被绕过、脚本存在注入风险），
**请不要开公开 issue**，先通过仓库的 GitHub Security Advisory
（Security → Report a vulnerability）私下提交。
