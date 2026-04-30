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
  apt install -y openssh-server stunnel4 socat curl ufw fail2ban qrencode
}

stop_conflicts(){
  # Free 443/8443 if something grabbed them
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
  log "Hardening SSH..."
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  grep -q "ClientAliveInterval" /etc/ssh/sshd_config || echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
  grep -q "ClientAliveCountMax" /etc/ssh/sshd_config || echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config
  grep -q "TCPKeepAlive" /etc/ssh/sshd_config || echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config
  grep -q "Ciphers aes128-ctr" /etc/ssh/sshd_config || echo "Ciphers aes128-ctr" >> /etc/ssh/sshd_config
}

setup_udp_helper(){
  log "Starting simple UDP helper (7300)..."
  pkill socat 2>/dev/null || true
  nohup socat UDP-LISTEN:7300,fork UDP:8.8.8.8:53 >/dev/null 2>&1 &
}

setup_sysctl(){
  log "Applying TCP tuning (BBR)..."
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
  ufw allow 22 || true
  ufw allow 443 || true
  ufw allow 8443 || true
  ufw allow 7300/udp || true
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
  log "Verifying listeners..."
  ss -tulnp | grep -E ':443|:8443' || fail "TLS ports not open"
  ss -u -lpn | grep ':7300' || warn "UDP helper not visible"
}

show_info(){
  IP=$(curl -s ifconfig.me)
  echo "======================================"
  echo "✅ READY"
  echo "IP: $IP"
  echo "TLS Ports: 443 / 8443"
  echo "UDP helper: 7300"
  echo "======================================"
}

# -------- Optional: WireGuard (real UDP VPN) --------
install_wireguard(){
  log "Installing WireGuard..."
  apt install -y wireguard
  umask 077
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub

  read -p "Enter server public IP: " PUBIP
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)

PostUp = ufw route allow in on wg0 out on eth0; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = ufw route delete allow in on wg0 out on eth0; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

  sysctl -w net.ipv4.ip_forward=1
  systemctl enable wg-quick@wg0
  systemctl start wg-quick@wg0

  log "WireGuard installed (port 51820/UDP)."
  echo "Server public key:"
  cat /etc/wireguard/server.pub
}

update_script(){
  log "Updating script..."
  curl -s $REPO/setup-vpn-pro.sh -o setup-vpn-pro.sh
  chmod +x setup-vpn-pro.sh
  log "Updated!"
}

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

menu(){
  clear
  echo "======================================"
  echo " ULTIMATE VPS INSTALLER"
  echo "======================================"
  echo "1) Full Install (SSH + TLS)"
  echo "2) Install WireGuard (UDP VPN)"
  echo "3) Update Script"
  echo "4) Exit"
  echo ""
  read -p "Choose: " opt

  case $opt in
    1) full_install ;;
    2) install_wireguard ;;
    3) update_script ;;
    4) exit ;;
    *) echo "Invalid" ;;
  esac
}

while true; do menu; done
