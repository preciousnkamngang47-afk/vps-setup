#!/bin/bash
set -e

REPO="https://raw.githubusercontent.com/preciousnkamngang47-afk/vps-setup/main"

log(){ echo -e "\n[✔] $1\n"; }
warn(){ echo -e "\n[!] $1\n"; }
fail(){ echo -e "\n[✘] $1\n"; }

fix_dpkg(){
  killall apt apt-get 2>/dev/null || true
  dpkg --configure -a || true
}

install_base(){
  log "Updating & installing base packages..."
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
    qrencode
}

stop_conflicts(){
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
}

setup_stunnel(){
  log "Configuring Stunnel (443, 8443)..."

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

setup_ssh(){
  log "Configuring SSH..."

  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config

  grep -q "ClientAliveInterval" /etc/ssh/sshd_config || \
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config

  grep -q "ClientAliveCountMax" /etc/ssh/sshd_config || \
    echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config

  grep -q "TCPKeepAlive" /etc/ssh/sshd_config || \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config

  grep -q "Ciphers aes128-ctr" /etc/ssh/sshd_config || \
    echo "Ciphers aes128-ctr" >> /etc/ssh/sshd_config
}

setup_udp_helper(){
  log "Starting UDP helper..."

  pkill socat 2>/dev/null || true

  nohup socat UDP-LISTEN:7300,fork UDP:8.8.8.8:53 \
    >/dev/null 2>&1 &
}

setup_sysctl(){
  log "Applying TCP optimization..."

  grep -q "tcp_congestion_control" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<EOF

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  sysctl -p || true
}

setup_firewall(){
  log "Configuring firewall..."

  ufw allow 22/tcp || true
  ufw allow 443/tcp || true
  ufw allow 8443/tcp || true
  ufw allow 7300/udp || true
  ufw allow 5300/udp || true

  ufw --force enable || true
}

setup_fail2ban(){
  log "Enabling fail2ban..."

  systemctl enable fail2ban
  systemctl restart fail2ban
}

restart_services(){
  log "Restarting services..."

  systemctl restart ssh || fail "SSH failed"
  systemctl restart stunnel4 || fail "Stunnel failed"
}

verify(){
  log "Verifying ports..."

  ss -tulnp | grep -E ':443|:8443' || \
    fail "TLS ports not listening"

  ss -u -lpn | grep ':7300' || \
    warn "UDP helper not detected"

  ss -u -lpn | grep ':5300' || \
    warn "SlowDNS not detected"
}

show_info(){
  IP=$(curl -4 -s ifconfig.me)

  echo ""
  echo "======================================"
  echo "✅ VPS READY"
  echo "======================================"
  echo "IP: $IP"
  echo "TLS PORTS: 443 / 8443"
  echo "UDP HELPER: 7300"
  echo "SLOWDNS: 5300"
  echo "======================================"
}

# =========================================
# WireGuard
# =========================================

install_wireguard(){

  log "Installing WireGuard..."

  apt install -y wireguard

  umask 077

  wg genkey | tee /etc/wireguard/server.key | \
    wg pubkey > /etc/wireguard/server.pub

  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)

PostUp = iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
EOF

  sysctl -w net.ipv4.ip_forward=1

  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0

  ufw allow 51820/udp

  log "WireGuard installed successfully."

  echo ""
  echo "SERVER PUBLIC KEY:"
  cat /etc/wireguard/server.pub
  echo ""
}

# =========================================
# SlowDNS
# =========================================

install_slowdns(){

  echo ""
  echo "=================================="
  echo "🔧 Installing SlowDNS"
  echo "=================================="

  apt update -y
  apt install -y git wget tar curl

  # remove old Go
  rm -rf /usr/local/go
  rm -f go1.22.5.linux-amd64.tar.gz

  # install Go
  wget -q https://go.dev/dl/go1.22.5.linux-amd64.tar.gz

  tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz

  export PATH=/usr/local/go/bin:$PATH
  hash -r

  echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc

  # download dnstt
  cd /root

  rm -rf dnstt

  git clone https://github.com/tladesignz/dnstt.git

  cd /root/dnstt/dnstt-server

  # build
  /usr/local/go/bin/go build

  # generate keys
  ./dnstt-server \
    -gen-key \
    -privkey-file server.key \
    -pubkey-file server.pub

  PUBKEY=$(cat server.pub)

  # create service
  cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/dnstt/dnstt-server
ExecStart=/root/dnstt/dnstt-server/dnstt-server -udp :5300 -privkey-file /root/dnstt/dnstt-server/server.key myvpn237.duckdns.org 127.0.0.1:22
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable slowdns
  systemctl restart slowdns

  ufw allow 5300/udp

  echo ""
  echo "=================================="
  echo "✅ SLOWDNS READY"
  echo "=================================="
  echo "NS: myvpn237.duckdns.org"
  echo "PUBKEY: $PUBKEY"
  echo "DNS: 1.1.1.1"
  echo "PORT: 5300 UDP"
  echo "=================================="
}

# =========================================
# Script updater
# =========================================

update_script(){

  log "Updating script..."

  curl -s $REPO/setup-vpn-pro.sh -o setup-vpn-pro.sh

  chmod +x setup-vpn-pro.sh

  log "Script updated."
}

# =========================================
# Full install
# =========================================

full_install(){

  install_base
  stop_conflicts
  setup_stunnel
  setup_ssh
  setup_udp_helper
  setup_sysctl
  setup_firewall
  setup_fail2ban
  restart_services
  verify
  show_info
}

# =========================================
# Menu
# =========================================

menu(){

  clear

  echo "======================================"
  echo " ULTIMATE VPS INSTALLER"
  echo "======================================"
  echo "1) Full Install (SSH + TLS)"
  echo "2) Install WireGuard"
  echo "3) Install SlowDNS"
  echo "4) Update Script"
  echo "5) Exit"
  echo ""

  read -p "Choose: " opt

  case $opt in
    1) full_install ;;
    2) install_wireguard ;;
    3) install_slowdns ;;
    4) update_script ;;
    5) exit ;;
    *) echo "Invalid option" ;;
  esac

  echo ""
  read -p "Press Enter to continue..."
}

while true; do
  menu
done
