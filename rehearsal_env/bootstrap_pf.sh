#!/usr/bin/env bash
# 跳板机执行：把 canal-admin 的 port-forward 交给 systemd 托管（替代原 setsid nohup 裸跑，
# 解决 bastion_host.md 已知坑 #5：常驻进程重启后不自启）。
set -uo pipefail

cat > /etc/systemd/system/canal-admin-pf.service <<'EOF'
[Unit]
Description=kubectl port-forward canal-admin 8089 (canal rehearsal)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=KUBECONFIG=/root/.kube/config
Environment=AWS_REGION=us-east-1
ExecStart=/usr/local/bin/kubectl -n common-service port-forward svc/canal-admin 8089:8089 --address 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now canal-admin-pf.service
sleep 6
systemctl is-active canal-admin-pf.service
systemctl is-enabled canal-admin-pf.service

echo "=== 端口探测 ==="
for i in $(seq 1 20); do
  if curl -s -m 3 -o /dev/null http://127.0.0.1:8089/; then echo "8089 就绪"; break; fi
  sleep 3
done

echo "=== 登录探测（默认 admin/123456）==="
curl -s -m 8 -X POST http://127.0.0.1:8089/api/v1/user/login \
  -H 'Content-Type: application/json' -d '{"username":"admin","password":"123456"}' | head -c 400
echo
echo "DONE"
