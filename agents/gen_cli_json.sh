#!/usr/bin/env bash
# 从 canal-cutover.md（唯一真源）生成 CLI 载体 canal-cutover.cli.json。
#
# 为什么需要两个载体（2026-08-17 本机实测，Kiro CLI 2.18.1 / Kiro IDE 1.0.309）：
#   1. CLI 2.18.1 不认 Markdown 定义：
#      `kiro-cli agent validate --path xxx.md`
#      → Error: Json supplied at xxx.md is invalid: invalid number at line 1 column 2
#   2. CLI 2.18.1 不执行 frontmatter 里的 permissions 规则，且不告警：
#      给探针 agent 配 deny shell "echo *"，命令照样执行成功；
#      `agent validate` 连完全瞎编的字段都返回退出码 0（宽松校验，证明"通过"不代表"生效"）。
#      → 所以本脚本刻意**不把 permissions 写进 JSON**：写进去只会造成"看起来配了门禁"的假象。
#      CLI 侧的门禁靠 2.x 真正执行的机制：allowedTools 白名单（仅 fs_read 免批，
#      每条 shell 命令都要人按 y/t）+ 脚本内置 YES 确认 + 契约本身。
#   3. IDE 1.0.309 则确实强制 permissions（deny 命中时命令不执行，提示点名规则与来源作用域），
#      所以 md 里的 permissions 对 IDE 有效，保留。
#
# 用法：bash agents/gen_cli_json.sh   （在 runbook 根目录执行）
# 生成后请跑：kiro-cli-chat agent validate --path agents/canal-cutover.cli.json
set -euo pipefail

cd "$(dirname "$0")/.."
SRC=agents/canal-cutover.md
DST=agents/canal-cutover.cli.json
[ -f "$SRC" ] || { echo "FATAL: 未找到 $SRC"; exit 1; }

python3 - "$SRC" "$DST" <<'PY'
import json, re, sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()

m = re.match(r'^---\n(.*?)\n---\n(.*)$', text, re.S)
if not m:
    sys.exit('FATAL: %s 缺少 YAML frontmatter' % src)
front, body = m.group(1), m.group(2).strip()

def field(key):
    mm = re.search(r'^%s:\s*"?(.*?)"?\s*$' % key, front, re.M)
    return mm.group(1) if mm else None

name = field('name') or 'canal-cutover'
desc = field('description') or ''

# CLI 侧补充：绝对路径与门禁语义差异。setup_cli_agent.sh 会把这里的路径按目标机重写。
cli_supplement = """

## CLI 环境补充（Kiro CLI 2.18.1）

堡垒机上 runbook 根目录为 /root/canal_cutover_agent（含 steering/、scripts/、state/）。
会话开始时先完整读取 steering/canal-cutover-runbook.md 与 README.md。

**本载体没有声明式策略层。** CLI 2.18.1 不执行 md frontmatter 里的 permissions 规则，
因此上文提到的"策略已 deny/allow"在 CLI 会话中并不成立：这里每条 shell 命令都会弹出
y/t 确认，只有 fs_read 免批。也就是说——
- 禁区命令没有机器拦截，**只有你的契约在拦**：`aws rds switchover-*`、`modify-*`、
  `kubectl delete/apply/edit/scale`、`cleanup.sh`、`cdk destroy`、`sudo`、`rm -r`
  一律不许发起，一次都不许；
- 变更脚本（20/22/24）的请示纪律是唯一的第一道防线，不要依赖弹窗替你把关；
- 口令文件（~/.canal/secrets.sh）与密钥没有 fs_read 拦截，**你自己不许去读**，
  脚本会自行加载，你不需要看到明文。"""

cfg = {
    "name": name,
    "description": desc,
    "prompt": body + cli_supplement,
    # tools/allowedTools 是 CLI 2.x 真正执行的权限机制，沿用 2026-07-23 演练实测有效的组合：
    # fs_read 免批用于取证，其余（含 execute_bash）每条命令都要人确认。
    "tools": ["*"],
    "allowedTools": ["fs_read"],
    "resources": [
        "file:///root/canal_cutover_agent/steering/canal-cutover-runbook.md",
        "file:///root/canal_cutover_agent/README.md",
    ],
}

with open(dst, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')

print('已生成 %s' % dst)
print('  name        = %s' % name)
print('  prompt 字数  = %d' % len(cfg['prompt']))
print('  allowedTools = %s（其余工具逐条确认）' % cfg['allowedTools'])
assert 'permissions' not in cfg, 'CLI 载体不得包含 permissions'
print('  permissions  = 刻意省略（CLI 2.18.1 会静默忽略，写入即造成虚假安全感）')
PY
