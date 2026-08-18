#!/usr/bin/env bash
# 只读探测 canal-admin 1.1.8 REST 端点，确认集群/配置/模板的可用路径。
# 口令默认取 canal-admin 的**上游公开默认值** admin/123456（刚部署、还没改密时用）；
# 已改密的环境请 export ADMIN_PASSWD=... 再跑。生产环境不要保留默认口令。
set -uo pipefail
API=${ADMIN_API:-http://127.0.0.1:8089}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWD=${ADMIN_PASSWD:-123456}
TK=$(curl -s -m 8 -X POST $API/api/v1/user/login -H 'Content-Type: application/json' \
  -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWD}\"}" | jq -r '.data.token')
echo "token=${TK:0:8}..."

probe() {
  printf '%-58s ' "$1"
  curl -s -m 8 -o /tmp/p.out -w '%{http_code} ' -H "X-Token: $TK" "$API$1"
  head -c 220 /tmp/p.out | tr -d '\n'
  echo
}

probe /api/v1/canal/clusters
probe '/api/v1/canal/clusters?page=1&size=20'
probe /api/v1/canal/nodeServers
probe '/api/v1/canal/nodeServers?page=1&size=20'
probe '/api/v1/canal/instances?page=1&size=20'
probe /api/v1/canal/config/1/1
probe /api/v1/canal/templates
probe /api/v1/canal/canalConfig
probe /api/v1/canal/template/canal
probe /api/v1/canal/template/instance
probe /api/v1/user/1
echo "DONE"
