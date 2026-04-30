#!/bin/bash

REPO="https://raw.githubusercontent.com/preciousnkamngang47-afk/vps-setup/main"

clear
echo "======================================"
echo " VPS INSTALLER PRO MENU"
echo "======================================"

menu() {
echo ""
echo "1) Install SSH + TLS (Stunnel)"
echo "2) Install UDP Base"
echo "3) Install Domain + SSL"
echo "4) Update Script"
echo "5) Exit"
echo ""
read -p "Select option: " opt

case $opt in

1)
echo "Installing SSH + TLS..."
apt update -y && apt upgrade -y
apt install -y openssh-server stunnel4 nginx

openssl req -new -x509 -days 3650 -nodes \
-out /etc/stunnel/stunnel.pem \
-keyout /etc/stunnel/stunnel.pem \
-subj "/CN=localhost"

cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel.pid
cert = /etc/stunnel/stunnel.pem

[ssh]
accept = 443
connect = 127.0.0.1:22
EOF

sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

systemctl restart ssh
systemctl restart stunnel4

echo "Done: SSH over TLS running on port 443"
;;

2)
echo "Installing UDP base..."
apt install -y socat

nohup socat UDP-LISTEN:7300,fork UDP:8.8.8.8:53 >/dev/null 2>&1 &

echo "UDP running on port 7300"
;;

3)
echo "Installing Domain + SSL..."

read -p "Enter your domain: " domain

apt install -y certbot python3-certbot-nginx

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $domain;

    location / {
        return 200 "OK";
    }
}
EOF

systemctl restart nginx

certbot --nginx -d $domain --non-interactive --agree-tos -m admin@$domain --redirect

echo "SSL installed for $domain"
;;

4)
echo "Updating script..."
curl -s $REPO/setup-vpn-pro.sh -o setup-vpn-pro.sh
chmod +x setup-vpn-pro.sh
echo "Updated successfully!"
;;

5)
exit
;;

*)
echo "Invalid option"
;;

esac
}

while true; do
menu
done
