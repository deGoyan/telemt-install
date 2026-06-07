#!/bin/bash
set -e

# [Основано на контексте myTelemt]
# Предотвращаем интерактивные запросы APT в Ubuntu 24.04
export DEBIAN_FRONTEND=noninteractive

echo "================================================================"
echo "=== Интерактивная настройка Telemt + Certbot (Ubuntu 24.04) ==="
echo "================================================================"
echo ""

# 1. Запрос домена
while [ -z "$DOMAIN" ]; do
    read -p "Введите ваш домен (A-запись должна указывать на этот IP): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "Ошибка: Домен не может быть пустым."
    fi
done

# 2. Запрос HEX-секрета
read -p "Введите 32-значный HEX-секрет (оставьте пустым для автогенерации): " USER_SECRET

if [ -z "$USER_SECRET" ]; then
    echo "Секрет не введен. Генерирую автоматически..."
    HEX_SECRET=$(openssl rand -hex 16)
else
    if [[ ! "$USER_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "Ошибка: Секрет должен быть ровно 32 символа HEX (0-9, a-f)."
        exit 1
    else
        HEX_SECRET=$(echo "$USER_SECRET" | tr '[:upper:]' '[:lower:]')
    fi
fi

echo ""
echo "=== Параметры приняты. Начинается установка ==="
echo "Домен: $DOMAIN"
echo "HEX-секрет: $HEX_SECRET"
echo "==============================================="
sleep 2

echo "=== Шаг 0. Обновление ОС и установка базовых компонентов ==="
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confold"

# Установка системных утилит и certbot
apt-get install -y curl wget xxd sed iptables ipset iptables-persistent nginx certbot

echo "iptables-persistent iptables-persistent/tosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/tosave_v6 boolean true" | debconf-set-selections

# Временно останавливаем дефолтный Nginx, чтобы освободить 80 порт для утилиты certbot
systemctl stop nginx

echo "=== Шаг 0.1. Автоматическое получение SSL-сертификата Let's Encrypt ==="
# Запрашиваем сертификат в режиме standalone без указания email
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "${DOMAIN}"

# Проверяем физическое наличие файлов сертификатов перед продолжением
if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "Ошибка: Не удалось получить SSL-сертификат для домена ${DOMAIN}."
    echo "Проверьте, что A-запись домена указывает на IP этого сервера, и порт 80 открыт."
    exit 1
fi

echo "=== Шаг 1. Установка ядра telemt ==="
wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-$(uname -m)-linux-$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu).tar.gz" | tar -xz
mv telemt /bin/telemt
chmod +x /bin/telemt

echo "=== Шаг 2. Базовая конфигурация ==="
mkdir -p /etc/telemt

cat << EOF > /etc/telemt/telemt.toml
[general]
use_middle_proxy = true

[general.modes]
classic = false
secure = false
tls = true

[network]
ipv4 = true
ipv6 = false
prefer = 4

[server]
port = 443
listen_addr_ipv4 = "0.0.0.0"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8"]

[censorship]
tls_domain = "${DOMAIN}"
mask = true
mask_port = 8443
mask_host = "127.0.0.1"
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
tg_user = "${HEX_SECRET}"
EOF

echo "=== Шаг 3. Изоляция службы Systemd ==="
useradd -d /etc/telemt -m -r -U telemt || true
chown -R telemt:telemt /etc/telemt

cat << EOF > /etc/systemd/system/telemt.service
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/etc/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now telemt

echo "=== Шаг 4. Настройка Nginx-заглушки ==="
cat << EOF > /etc/nginx/sites-available/telemt
server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers on;

    root /var/www/html;
    index index.nginx-debian.html index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /secret-panel/ {
        proxy_pass http://127.0.0.1:8080/secret-panel/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/telemt /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default || true

echo "=== Шаг 5. Защита от TCP RST инъекций (tspublock) ==="
curl -fsSL "https://stats.gptru.pro:4443/rst/api.php?action=export&fmt=iptables&src=cyberok" -o /tmp/tspublock.sh && bash /tmp/tspublock.sh
ipset create GOVIPS hash:net maxelem 65536 || true
curl -s "https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset" | grep "^add blacklist-v