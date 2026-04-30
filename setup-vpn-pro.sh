#!/bin/bash

echo "🚀 Starting PRO VPS Setup..."

# Update
apt update -y && apt upgrade -y

# Install packages
apt install -y openssh-server stunnel4 nginx socat

# Enable services
systemctl enable ssh
systemctl enable stunnel4
systemctl enable nginx

# ========================
# 🔐 STUNNEL (TLS 443)
# ========================
echo "🔐 Generating SSL cert..."
openssl req -new -x509 -days 3650 -nodes \
-out /etc/stunnel/stunnel.pem \
-keyout /etc/stunnel/stunnel.pem \
-subj "/C=US/ST=VPN/L=Server/O=VPN/OU=VPN/CN=localhost"

chmod 600 /etc/stunnel/stunnel.pem

cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
cert = /etc/stunnel/stunnel.pem

[ssh]
accept = 443
connect = 127.0.0.1:22
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
EOF

sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

# ========================
# ⚡ SSH OPTIMIZATION
# ========================
echo "⚡ Optimizing SSH..."
cat >> /etc/ssh/sshd_config <<EOF

Compression yes
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
Ciphers aes128-ctr
EOF

# ========================
# 🚀 UDP SUPPORT (UDPGW)
# ========================
echo "📡 Setting up UDP support..."
# Simple UDP gateway using socat (port 7300 like your app)
nohup socat UDP-LISTEN:7300,fork UDP:8.8.8.8:53 >/dev/null 2>&1 &

# ========================
# 🌐 OPTIONAL WEBSOCKET (WSS)
# ========================
echo "🌐 Configuring Nginx (WSS support)..."

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name _;

    location /ws {
        proxy_pass http://127.0.0.1:22;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

# ========================
# ⚙️ NETWORK OPTIMIZATION
# ========================
echo "🚀 Applying network tuning..."

cat >> /etc/sysctl.conf <<EOF

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p

# ========================
# 🔥 FIREWALL
# ========================
if command -v ufw >/dev/null 2>&1; then
    ufw allow 22
    ufw allow 443
    ufw allow 7300/udp
    ufw --force enable
fi

# ========================
# 🔄 RESTART SERVICES
# ========================
systemctl restart ssh
systemctl restart stunnel4
systemctl restart nginx

echo "✅ SETUP COMPLETE!"
echo "=================================="
echo "SSH + TLS:"
echo "Port: 443"
echo ""
echo "UDP:"
echo "Port: 7300"
echo ""
echo "WebSocket (optional):"
echo "Path: /ws"
echo "=================================="
