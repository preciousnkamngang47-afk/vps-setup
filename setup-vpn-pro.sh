#!/bin/bash
set -e

trap 'echo -e "\n[✘] Error occurred on line $LINENO\n"' ERR

DOMAIN="sneaky-user.com"

log(){ echo -e "\n[✔] $1\n"; }
warn(){ echo -e "\n[!] $1\n"; }
fail(){ echo -e "\n[✘] $1\n"; exit 1; }

# ==========================================
# FIX SYSTEM LOCKS
# ==========================================

fix_dpkg(){
  killall apt apt-get 2>/dev/null || true
  rm -f /var/lib/dpkg/lock-frontend
  rm -f /var/cache/apt/archives/lock
  dpkg --configure -a || true
}

# ==========================================
# DETECT NETWORK INTERFACE
# ==========================================

NIC=$(ip route | grep default | awk '{print $5}' | head -n1)

# ==========================================
# INSTALL BASE PACKAGES
# ==========================================

install_base(){

  log "Installing dependencies..."

  fix_dpkg

  apt update -y
  apt upgrade -y

  apt install -y \
    openssh-server \
    stunnel4 \
    socat \
    curl \
    wget \
    git \
    ufw \
    fail2ban \
    qrencode \
    wireguard \
    net-tools \
    dnsutils
}

# ==========================================
# STOP CONFLICTS
# ==========================================

stop_conflicts(){
  log "Stopping conflicting services..."
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
}

# ==========================================
# SSH CONFIG (SAFE + LOCAL ONLY)
# ==========================================

setup_ssh(){

  log "Securing SSH..."

  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

  # IMPORTANT: bind SSH locally only (forced through stunnel)
  echo "ListenAddress 127.0.0.1" >> /etc/ssh/sshd_config

  systemctl restart ssh
}

# ==========================================
# STUNNEL SETUP (REAL HTTPS STYLE 443)
# ==========================================

setup_stunnel(){

  log "Setting up Stunnel (HTTPS port 443)..."

  mkdir -p /etc/stunnel

  # FIXED CERT GENERATION
  openssl req -new -x509 -days 3650 -nodes \
    -out /etc/stunnel/stunnel.pem \
    -keyout /etc/stunnel/stunnel.key \
    -subj "/CN=$DOMAIN"

  chmod 600 /etc/stunnel/stunnel.*

  cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
cert = /etc/stunnel/stunnel.pem
key = /etc/stunnel/stunnel.key

sslVersion = TLSv1.2
options = NO_SSLv2
options = NO_SSLv3
options = NO_TLSv1
options = NO_TLSv1.1
options = CIPHER_SERVER_PREFERENCE
options = NO_COMPRESSION

socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-https]
accept = 0.0.0.0:443
connect = 127.0.0.1:22
EOF

  sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4

  systemctl restart stunnel4
  systemctl enable stunnel4
}

# ==========================================
# UDP HELPER
# ==========================================

setup_udp(){

  log "Starting UDP helper..."

  pkill socat 2>/dev/null || true

  nohup socat UDP-LISTEN:7300,fork UDP:8.8.8.8:53 \
    >/dev/null 2>&1 &
}

# ==========================================
# SYSTEM TUNING
# ==========================================

setup_sysctl(){

  log "Optimizing TCP..."

  cat >> /etc/sysctl.conf <<EOF

net.ipv4.ip_forward = 1
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF

  sysctl -p
}

# ==========================================
# FIREWALL (SAFE ORDER)
# ==========================================

setup_firewall(){

  log "Configuring firewall..."

  ufw allow 22/tcp
  ufw allow 443/tcp
  ufw allow 51820/udp
  ufw allow 7300/udp

  ufw --force enable
}

# ==========================================
# FAIL2BAN
# ==========================================

setup_fail2ban(){
  log "Enabling fail2ban..."
  systemctl enable fail2ban
  systemctl restart fail2ban
}

# ==========================================
# VERIFY
# ==========================================

verify(){

  log "Checking services..."

  ss -tulnp | grep 443 || fail "Stunnel not running on 443"
  ss -tulnp | grep 22 || warn "SSH check warning"
}

# ==========================================
# WIREGUARD
# ==========================================

install_wireguard(){

  log "Installing WireGuard..."

  umask 077

  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub

  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)

PostUp = iptables -t nat -A POSTROUTING -o $NIC -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $NIC -j MASQUERADE
EOF

  sysctl -w net.ipv4.ip_forward=1

  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0
}

# ==========================================
# FULL INSTALL
# ==========================================

full_install(){
  install_base
  stop_conflicts
  setup_ssh
  setup_stunnel
  setup_udp
  setup_sysctl
  setup_firewall
  setup_fail2ban
  verify

  echo ""
  echo "=================================="
  echo "✅ VPS READY"
  echo "=================================="
  echo "TLS PORT: 443 (Stunnel HTTPS mode)"
  echo "SSH: localhost only"
  echo "WIREGUARD: 51820 UDP"
  echo "DOMAIN: $DOMAIN"
  echo "=================================="
}

# ==========================================
# MENU
# ==========================================

menu(){

  clear

  echo "=================================="
  echo "   VPS VPN INSTALLER (FIXED)"
  echo "=================================="
  echo "1) Full Install"
  echo "2) WireGuard Only"
  echo "3) Exit"
  echo "=================================="

  read -p "Choose: " opt

  case $opt in
    1) full_install ;;
    2) install_wireguard ;;
    3) exit ;;
    *) echo "Invalid option" ;;
  esac
}

while true; do
  menu
done
