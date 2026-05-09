#!/bin/bash
set -e

# ==============================
# GLOBAL CONFIG
# ==============================

DOMAIN="myvpn237.duckdns.org"
REPO="https://raw.githubusercontent.com/preciousnkamngang47-afk/vps-setup/main"

log(){ echo -e "\n[✔] $1\n"; }
warn(){ echo -e "\n[!] $1\n"; }
fail(){ echo -e "\n[✘] $1\n"; }

fix_dpkg(){
  killall apt apt-get 2>/dev/null || true
  dpkg --configure -a || true
}

# ==============================
# BASE INSTALL
# ==============================

install_base(){
  log "Installing base packages..."
  fix_dpkg

  apt update -y || fix_dpkg
  apt upgrade -y || true

  apt install -y \
    openssh-server \
    stunnel4 \
    socat \
    curl \
    wget \
    git \
    tar \
    ufw \
    fail2ban \
    qrencode \
    build-essential
}

stop_conflicts(){
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
}

# ==============================
# SSH CONFIG
# ==============================

setup_ssh(){
  log "Configuring SSH..."

  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config

  echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
  echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
  echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config
}

# ==============================
# STUNNEL (UNCHANGED CORE)
# ==============================

setup_stunnel(){
  log "Configuring Stunnel..."

  mkdir -p /etc/stunnel

  openssl req -new -x509 -days 3650 -nodes \
    -out /etc/stunnel/stunnel.pem \
    -keyout /etc/stunnel/stunnel.pem \
    -subj "/CN=localhost"

  chmod 600 /etc/stunnel/stunnel.pem

  cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
cert = /etc/stunnel/stunnel.pem

[ssh-443]
accept = 443
connect = 127.0.0.1:22

[ssh-8443]
accept = 8443
connect = 127.0.0.1:22

socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
EOF

  sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
}

# ==============================
# SYSTEM OPTIMIZATION (AGGRESSIVE)
# ==============================

setup_sysctl(){
  log "Applying aggressive network tuning..."

  cat >> /etc/sysctl.conf <<EOF

# ===== VPS SPEED BOOST =====
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 10000

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.ipv4.ip_forward = 1
EOF

  sysctl -p || true
}

# ==============================
# MTU OPTIMIZATION
# ==============================

setup_mtu(){
  log "Setting MTU for mobile networks..."
  ip link set dev eth0 mtu 1280 || true
}

# ==============================
# FIREWALL
# ==============================

setup_firewall(){
  log "Configuring firewall..."

  ufw allow 22/tcp || true
  ufw allow 443/tcp || true
  ufw allow 8443/tcp || true
  ufw allow 51820/udp || true
  ufw allow 5300/udp || true
  ufw allow 7300/udp || true

  ufw --force enable || true
}

# ==============================
# FAIL2BAN
# ==============================

setup_fail2ban(){
  systemctl enable fail2ban
  systemctl restart fail2ban
}

# ==============================
# SERVICES RESTART
# ==============================

restart_services(){
  systemctl restart ssh || true
  systemctl restart stunnel4 || true
}

# ==============================
# VERIFY
# ==============================

verify(){
  log "Checking ports..."

  ss -tulnp | grep -E ':443|:8443' || warn "Stunnel ports missing"
  ss -u -lpn | grep ':5300' || warn "SlowDNS not running"
  ss -u -lpn | grep ':7300' || warn "UDP helper missing"
}

# ==============================
# INFO DISPLAY
# ==============================

show_info(){
  IP=$(curl -4 -s ifconfig.me)

  echo ""
  echo "======================================"
  echo "🚀 VPS READY (AGGRESSIVE MODE)"
  echo "======================================"
  echo "IP: $IP"
  echo "DOMAIN: $DOMAIN"
  echo "TLS PORTS: 443 / 8443"
  echo "WIREGUARD: 51820"
  echo "SLOWDNS: 5300 UDP"
  echo "UDP HELPER: 7300"
  echo "======================================"
}

# ==============================
# WIREGUARD (UNCHANGED CORE)
# ==============================

install_wireguard(){
  log "Installing WireGuard..."

  apt install -y wireguard

  umask 077

  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub

  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)

PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

  sysctl -w net.ipv4.ip_forward=1

  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0

  ufw allow 51820/udp

  echo ""
  echo "WIREGUARD PUBLIC KEY:"
  cat /etc/wireguard/server.pub
}

# ==============================
# OPTIMIZED SLOWDNS (dnstt)
# ==============================

install_slowdns(){

  log "Installing OPTIMIZED SlowDNS..."

  apt update -y
  apt install -y git wget curl tar build-essential

  rm -rf /usr/local/go
  wget -q https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
  tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz

  export PATH=/usr/local/go/bin:$PATH
  echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc

  cd /root
  rm -rf dnstt
  git clone https://github.com/tladesignz/dnstt.git

  cd /root/dnstt/dnstt-server

  # AGGRESSIVE BUILD OPTIMIZATION
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w"

  ./dnstt-server \
    -gen-key \
    -privkey-file server.key \
    -pubkey-file server.pub

  PUBKEY=$(cat server.pub)

  cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=Optimized SlowDNS Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/dnstt/dnstt-server

ExecStart=/root/dnstt/dnstt-server/dnstt-server \
-udp :5300 \
-privkey-file /root/dnstt/dnstt-server/server.key \
-ttl 25 \
$DOMAIN \
127.0.0.1:22

Restart=always
RestartSec=1
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable slowdns
  systemctl restart slowdns

  ufw allow 5300/udp

  echo ""
  echo "=================================="
  echo "⚡ SLOWDNS READY (OPTIMIZED)"
  echo "=================================="
  echo "DOMAIN: $DOMAIN"
  echo "PUBKEY: $PUBKEY"
  echo "DNS: 1.1.1.1"
  echo "PORT: 5300 UDP"
  echo "=================================="
}

# ==============================
# FULL INSTALL
# ==============================

full_install(){
  install_base
  stop_conflicts
  setup_stunnel
  setup_ssh
  setup_sysctl
  setup_mtu
  setup_firewall
  setup_fail2ban
  restart_services
  verify
  show_info
}

# ==============================
# MENU
# ==============================

menu(){
  clear

  echo "======================================"
  echo " 🚀 AGGRESSIVE VPS INSTALLER"
  echo "======================================"
  echo "1) Full Install (SSH + TLS)"
  echo "2) Install WireGuard"
  echo "3) Install Optimized SlowDNS"
  echo "4) Exit"
  echo ""

  read -p "Choose: " opt

  case $opt in
    1) full_install ;;
    2) install_wireguard ;;
    3) install_slowdns ;;
    4) exit ;;
    *) echo "Invalid option" ;;
  esac

  read -p "Press Enter..."
}

while true; do
  menu
done
