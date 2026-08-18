#!/usr/bin/env bash
# 从 canal-cutover.md（唯一真源）生成 CLI 载体 canal-cutover.cli.json。
#
# ⚠️ 前提条件（本版起）：堡垒机上的 CLI 会话必须以 v3 启动（`kiro-cli --v3`）。
#
# 版本前提的演变（保留历史，防止回退时想当然）：
#   1. CLI 2.18.1（2026-08-17 实测）：
#      - 不认 Markdown 定义（agent validate 对 .md 直接报 JSON 解析错误）；
#      - 不执行 permissions 且不告警（deny 的命令照样跑，validate 连瞎编字段都通过）。
#      → 当时的 JSON 载体刻意不含 permissions，门禁靠 allowedTools（仅 fs_read 免批，
#        每条 shell 命令人工 y/t）+ 脚本 YES + 契约。
#   2. CLI 3.0（kiro.dev/docs/cli/v3/，文档结论）：与 IDE 共用 unified harness，
#      agent 内嵌 permissions 是被评估的作用域（deny > ask > allow）。
#      → 本脚本改为把 md frontmatter 里的 permissions **原样带入 JSON**，
#        与 IDE 载体同源同规则。此为文档结论，非实测：部署脚本
#        （rehearsal_env/setup_cli_agent.sh）会先跑 deny 冒烟探针，探针不过不许开工。
#   3. 仍保留 JSON 载体（而非直接用 .md）：CLI 侧要注入堡垒机绝对路径 resources
#      与「CLI 环境补充」段，setup_cli_agent.sh 依赖 JSON 做路径重写。
#   4. 兼容性兜底：若误在 2.x 里加载本 JSON，permissions 被静默忽略，
#      门禁退化为 allowedTools 语义（除 fs_read 外每条命令都弹确认）——只会更吵，
#      不会更松；但 deny 禁区随之失效，所以 v3 启动是硬性前提而非建议。
#
# 依赖：python3 + PyYAML（解析 md frontmatter）。
# 用法：bash agents/gen_cli_json.sh   （在 runbook 根目录执行）
# 生成后：
#   kiro-cli --v3 agent validate --path agents/canal-cutover.cli.json
#   （validate 是宽松校验，通过≠生效；生效以部署时的 deny 冒烟探针为准）
set -euo pipefail

cd "$(dirname "$0")/.."
SRC=agents/canal-cutover.md
DST=agents/canal-cutover.cli.json
[ -f "$SRC" ] || { echo "FATAL: 未找到 $SRC"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || {
  echo "FATAL: python3 缺少 PyYAML（解析 md frontmatter 需要）。pip3 install pyyaml 后重试。"
  exit 1
}

python3 - "$SRC" "$DST" <<'PY'
import json, re, sys, yaml

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()

m = re.match(r'^---\n(.*?)\n---\n(.*)$', text, re.S)
if not m:
    sys.exit('FATAL: %s 缺少 YAML frontmatter' % src)
front, body = yaml.safe_load(m.group(1)), m.group(2).strip()

# ---------- 从真源提取，缺关键块直接失败，不做静默降级 ----------
perms = front.get('permissions')
if not perms or not perms.get('rules'):
    sys.exit('FATAL: %s frontmatter 缺少 permissions.rules——真源被改坏了，先修 md' % src)

rules = perms['rules']

def patterns(capability, effect):
    out = []
    for r in rules:
        if r.get('capability') == capability and r.get('effect') == effect:
            out += r.get('match') or []
    return out

# 防呆断言：真源若被编辑掉关键围栏，生成即失败（宁可不生成，不生成一份缺围栏的载体）
fence_checks = [
    ('shell deny 缺 switchover 围栏',
     any('switchover' in p for p in patterns('shell', 'deny'))),
    ('shell deny 缺 sudo 围栏',
     any(p.startswith('sudo') for p in patterns('shell', 'deny'))),
    ('变更脚本(20/22/24)未处于 ask',
     all(any('scripts/%s_' % n in p for p in patterns('shell', 'ask'))
         for n in ('20', '22', '24'))),
    ('fs_read deny 缺口令文件围栏',
     any('secrets.sh' in p for p in patterns('fs_read', 'deny'))),
    ('fs_write deny 缺 scripts/ 围栏',
     any('scripts' in p for p in patterns('fs_write', 'deny'))),
]
failed = [name for name, ok in fence_checks if not ok]
if failed:
    sys.exit('FATAL: 真源围栏检查未过: %s' % '; '.join(failed))

# ---------- CLI 侧补充段：v3 语义。setup_cli_agent.sh 会按目标机重写路径。 ----------
cli_supplement = """

## CLI 环境补充（Kiro CLI v3，`kiro-cli --v3` 启动为硬性前提）

堡垒机上 runbook 根目录为 /root/canal_cutover_agent（含 steering/、scripts/、state/）。
会话开始时先完整读取 steering/canal-cutover-runbook.md 与 README.md。

**本载体携带与 md 真源完全相同的 permissions 策略层**，由 v3 harness 强制执行：
只读/造数脚本 allow、变更脚本（20/22/24）ask、禁区命令 deny、文件写入仅放开 state/、
口令文件不可读。上文关于"策略已 deny/allow"的表述在本会话中同样成立。

但记住两条：
- 策略生效的前提是会话确实运行在 v3。部署脚本已做版本闸门与 deny 冒烟探针；
  若你在会话中发现 deny 禁区命令没有被拦的迹象，按 2.x 处理：**立即停止**，
  要求操作者以 `kiro-cli --v3` 重启会话，在此之前你的契约是唯一防线。
- 策略照旧拦不住"时机错误"。变更脚本的请示纪律（动作 + 证据 + 回滚，等用户明确批准）
  不因策略层存在而免除。口令文件（~/.canal/secrets.sh）虽有 fs_read deny 兜底，
  你也不许主动尝试读取——脚本会自行加载，你不需要看到明文。"""

cfg = {
    "name": front.get('name') or 'canal-cutover',
    "description": front.get('description') or '',
    "prompt": body + cli_supplement,
    # tools 与 md 同源（tag 写法，v3/IDE 通用）；visibility 层就关掉 web/mcp/subagent
    "tools": front.get('tools') or ["*"],
    # v3 下 fs_read 本就默认放行工作区内读取；保留 allowedTools 是 2.x 误载时的
    # 退化兜底（届时除 fs_read 外全部弹确认）。deny > allow，不影响口令文件围栏。
    "allowedTools": ["fs_read"],
    # permissions 原样带入：与 IDE 载体同一套规则，真源只有 md 一处
    "permissions": perms,
    "resources": [
        "file:///root/canal_cutover_agent/steering/canal-cutover-runbook.md",
        "file:///root/canal_cutover_agent/README.md",
    ],
}
for k in ('includeMcpJson', 'includePowers'):
    if k in front:
        cfg[k] = front[k]

with open(dst, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')

by_effect = {}
for r in rules:
    by_effect[r['effect']] = by_effect.get(r['effect'], 0) + 1
print('已生成 %s' % dst)
print('  name         = %s' % cfg['name'])
print('  tools        = %s' % cfg['tools'])
print('  prompt 字数   = %d' % len(cfg['prompt']))
print('  permissions  = %d 条规则 %s（与 md 真源同源）' % (len(rules), by_effect))
print('  围栏自检      = switchover/sudo deny、20/22/24 ask、secrets fs_read deny、scripts fs_write deny 全部在位')
print('  下一步        = kiro-cli --v3 agent validate --path %s' % dst)
print('                 部署时由 setup_cli_agent.sh 跑 deny 冒烟探针，探针不过不开工')
PY
