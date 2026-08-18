#!/usr/bin/env bash
# 跳板机执行：switchover 后的位点修补（副本 switchover 失败的修正路径）
#
# 背景：B/G 聚合状态 SWITCHOVER_COMPLETED，但 SwitchoverDetails 显示 reader 成员
# SWITCHOVER_FAILED（原因：绿 reader 当时处于 recovery/restart，复制停止）。
# 因此原 reader 名仍指向冻结的 8.0.42 旧副本，canal 的 master.address 与 env.sh 的
# GREEN_RO_HOST 都指错了对象。本脚本：
#   1) 存档现有 instance 配置
#   2) 把 GREEN_RO_HOST 指向真正的 8.4 reader
#   3) 用脚本（10_preflight_gtid.sh）在正确服务器上重算并集 —— 不手写并集
#   4) 改 master.address / master.gtid / master.timestamp（只动 content，不碰 cluster_id）
#   5) 回读逐字校验 + 跑 23_verify_config.sh
set -uo pipefail

EU=/home/ec2-user
RB=$EU/canal_cutover_agent

# 三个入参必须由调用方给出（本脚本刻意不带默认值——修补对象与基准位点错一个字就修错库）：
#   GREEN_READER_ENDPOINT  switchover 后 canal 真正要订阅的 8.4 reader endpoint
#                          （由 ssm_run.sh 透传；取值方式见 REHEARSAL_OPERATOR_RUNBOOK §3.1）
#   OLD_CURSOR_GTID        21_archive_cursor.sh 存档下来的 cursor gtid 集合
#   ARCHIVED_TS            同一份存档里 postion.timestamp 的毫秒值
NEW_RO="${GREEN_READER_ENDPOINT:?缺少 GREEN_READER_ENDPOINT（switchover 后逐成员核对得到的绿 reader）}"
OLD_CURSOR_GTID="${OLD_CURSOR_GTID:?缺少 OLD_CURSOR_GTID（取自 state/cursor_backup_*.json 的 postion.gtid）}"
ARCHIVED_TS="${ARCHIVED_TS:?缺少 ARCHIVED_TS（取自 state/cursor_backup_*.json 的 postion.timestamp）}"

. $EU/.canal/secrets.sh
export MYSQL_PWD="$DBADMIN_PWD"
mgr() { mysql -h "$PRIMARY" -u dbadmin -N -B --raw -e "$1"; }
asu() { sudo -u ec2-user -H env HOME=$EU PATH=$EU/.local/bin:/usr/local/bin:/usr/bin:/bin \
          AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 KUBECONFIG=$EU/.kube/config "$@"; }

SD=$(ls -d $RB/state/run_* | tail -1)
TS=$(date +%Y%m%d_%H%M%S)

echo "################ 0. 前置状态硬校验 ################"
asu bash -lc "cd $RB && source scripts/lib/common.sh && \
  echo instance_status=\$(admin_instance_op status) && \
  (zk_node_exists \"\$CURSOR_PATH\" && echo cursor=存在 || echo cursor=已删除)"
echo "--- 新 reader 必须是 8.4.x（这是本次事故的核心判据）---"
mysql -h "$NEW_RO" -u dbadmin -N -B -e "SELECT @@version, @@gtid_mode, @@binlog_format" 2>&1
V=$(mysql -h "$NEW_RO" -u dbadmin -N -B -e "SELECT @@version" 2>/dev/null)
case "$V" in 8.4.*) echo "OK: 目标 reader 是 $V" ;; *) echo "FATAL: 目标 reader 版本 $V 非 8.4.x，中止"; exit 1 ;; esac

echo
echo "################ 1. 存档现有配置（回滚用）################"
mgr "SELECT content FROM canal_manager.canal_instance_config WHERE name='server-0'" \
  > "$SD/instance_config_before_${TS}.properties"
wc -l "$SD/instance_config_before_${TS}.properties"
mgr "SELECT CONCAT('cluster_id=', IFNULL(cluster_id,'NULL'), ' status=', IFNULL(status,'NULL'), ' md5=', IFNULL(content_md5,'NULL')) FROM canal_manager.canal_instance_config WHERE name='server-0'"

echo
echo "################ 2. env.sh 的 GREEN_RO_HOST 指向真正的 8.4 reader ################"
python3 - "$RB/env.sh" "$NEW_RO" <<'PY'
import sys, io
path, newro = sys.argv[1], sys.argv[2]
src = open(path).read()
note = ('# ⚠️ 2026-08-15 switchover 后修正：B/G 的 reader 成员 SWITCHOVER_FAILED\n'
        '# （绿 reader 当时 recovery 中、复制停止），原 reader 名仍指向冻结的 8.0.42 旧副本。\n'
        '# 故此处显式写死真正的 8.4 reader endpoint，不再用 ${READER}。\n')
out = []
done = False
for line in src.splitlines(True):
    if line.startswith('export GREEN_RO_HOST='):
        out.append(note)
        out.append('export GREEN_RO_HOST="%s"\n' % newro)
        done = True
    else:
        out.append(line)
assert done, 'GREEN_RO_HOST 行未找到'
open(path, 'w').writelines(out)
print('env.sh 已更新')
PY
chown ec2-user:ec2-user "$RB/env.sh"; chmod 600 "$RB/env.sh"
asu bash -lc "cd $RB && . ./env.sh && echo GREEN_RO_HOST=\$GREEN_RO_HOST"

echo
echo "################ 3. 在正确服务器上重算并集（由脚本产出，不手写）################"
mv -f "$SD/gtid_union.txt" "$SD/gtid_union_WRONG_computed_on_old_reader_${TS}.txt" 2>/dev/null || true
asu bash -lc "cd $RB && bash scripts/10_preflight_gtid.sh '$OLD_CURSOR_GTID' 2>&1 | tail -12"
rc=$?
UNION=$(cat "$SD/gtid_union.txt" 2>/dev/null)
[ -n "$UNION" ] || { echo "FATAL: 并集文件为空，中止"; exit 1; }
echo "新并集: $UNION"

echo
echo "################ 4. 改 instance 配置（只动 content/content_md5）################"
UNION="$UNION" NEW_RO="$NEW_RO" TSV="$ARCHIVED_TS" \
  SRC="$SD/instance_config_before_${TS}.properties" DST="$SD/instance_config_after_${TS}.properties" \
  python3 - <<'PY'
import os, re, base64
repl = {
  'canal.instance.master.address':   os.environ['NEW_RO'] + ':3306',
  'canal.instance.master.gtid':      os.environ['UNION'].strip(),
  'canal.instance.master.timestamp': os.environ['TSV'],
}
lines = open(os.environ['SRC']).read().splitlines()
seen, out = set(), []
for line in lines:
    m = re.match(r'^([A-Za-z0-9_.]+)\s*=', line)
    if m and m.group(1) in repl:
        k = m.group(1)
        out.append('%s=%s' % (k, repl[k])); seen.add(k)
    else:
        out.append(line)
for k, v in repl.items():
    if k not in seen: out.append('%s=%s' % (k, v))
body = '\n'.join(out) + '\n'
open(os.environ['DST'], 'w').write(body)
open('/tmp/newcontent.b64', 'w').write(base64.b64encode(body.encode()).decode())
print('生成新配置，行数 =', len(out))
for k in repl:
    for l in out:
        if l.startswith(k + '='):
            print('  ', l if 'gtid' not in k else l[:70] + ('...' if len(l) > 70 else ''))
PY

B64=$(cat /tmp/newcontent.b64)
mysql -h "$PRIMARY" -u dbadmin -e "
UPDATE canal_manager.canal_instance_config
SET content = CONVERT(FROM_BASE64('$B64') USING utf8mb4),
    content_md5 = MD5(CONVERT(FROM_BASE64('$B64') USING utf8mb4))
WHERE name='server-0';" || { echo "FATAL: UPDATE 失败"; exit 1; }
rm -f /tmp/newcontent.b64

echo
echo "################ 5. 回读逐字校验 ################"
mgr "SELECT content FROM canal_manager.canal_instance_config WHERE name='server-0'" > "$SD/instance_config_readback_${TS}.properties"
if diff -q "$SD/instance_config_after_${TS}.properties" "$SD/instance_config_readback_${TS}.properties" >/dev/null; then
  echo "✅ 回读与预期逐字一致"
else
  echo "❌ 回读与预期不一致："; diff "$SD/instance_config_after_${TS}.properties" "$SD/instance_config_readback_${TS}.properties" | head -10
fi
echo "--- cluster_id 必须仍是 1（PUT API 的坑不适用于本路径，仍复核）---"
mgr "SELECT CONCAT('cluster_id=', IFNULL(cluster_id,'NULL'), ' status=', IFNULL(status,'NULL')) FROM canal_manager.canal_instance_config WHERE name='server-0'"
echo "--- 关键三行 ---"
grep -nE "^canal.instance.(master.address|master.gtid|master.timestamp|gtidon|tsdb.enable)=" "$SD/instance_config_readback_${TS}.properties"

echo
echo "################ 6. P2-4 校验（23_verify_config.sh）################"
asu bash -lc "cd $RB && bash scripts/23_verify_config.sh 2>&1 | tail -15; echo 退出码=\${PIPESTATUS[0]}"
echo "DONE"
