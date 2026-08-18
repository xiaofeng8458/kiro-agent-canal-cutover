#!/usr/bin/env bash
# 一次性 wrapper：非交互喂入确认短语并留存完整输出。
# 放在工作区而非 /tmp——/tmp 会被系统清理，实测导致后台进程启动即失败。
cd "$(dirname "$0")"
unset AWS_REGION
echo DELETE-REHEARSAL | bash cleanup.sh --execute 2>&1 | tee "cleanup_$(date +%Y%m%d_%H%M%S).out"
