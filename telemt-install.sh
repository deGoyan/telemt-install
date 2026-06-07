#!/bin/bash
set -e

# Предотвращаем любые интерактивные запросы APT в Ubuntu 24.04
export DEBIAN_FRONTEND=noninteractive

echo "================================================================"
echo "=== Тестовая автоматическая установка Telemt (Ubuntu 24.04) ==="
echo "================================================================"
echo ""

# 1. Запрос параметров у пользователя (выполняется строго ОДИН РАЗ в начале)
while [ -z "$DOMAIN" ]; do
    read -p "Введите ваш домен (A-запись должна указывать на этот IP): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "Ошибка: Домен не может быть пустым."
    fi
done

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
echo "=== Все параметры получены. Процесс полностью автономен ==="
echo "Домен: $DOMAIN"
echo "HEX-секрет: $HEX_SECRET"
echo "==============================================================="
sleep 1

echo "=== Шаг 0. Установка только необходимых компонентов (без dist-upgrade) ==="
apt-get update -y
apt-get install -y curl wget xxd sed iptables ipset iptables-persistent nginx certbot

echo "iptables-persistent iptables-persistent/tosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/tosave_v6 boolean true" | debconf-set-selections

# Очищаем дефолтные конфиги Nginx, чтобы исключить конфликты портов
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/default.conf

# Временно останавливаем Nginx для работы certbot
systemctl stop nginx || true

echo "=== Шаг 0.1. Получение SSL-сертификата Let's Encrypt ==="
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "${DOMAIN}"

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "Ошибка: Сертификат не получен. Проверьте DNS А-запись домена."
    exit 1
fi

echo "=== Шаг 1. Установка ядра telemt ==="
ARCH_NAME=$(uname -m)
wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH_NAME}-linux-$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu).tar.gz" | tar -xz
mv telemt /bin/telemt
chmod +x /bin/telemt

echo "=== Шаг 2. Базовая конфигурация ядра ==="
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

echo "=== Шаг 3. Создание службы Systemd для ядра ==="
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

echo "=== Шаг 5. Защита от TCP RST инъекций ==="
curl -fsSL "https://stats.gptru.pro:4443/rst/api.php?action=export&fmt=iptables&src=cyberok" -o /tmp/tspublock.sh && bash /tmp/tspublock.sh
ipset create GOVIPS hash:net maxelem 65536 || true
curl -s "https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset" | grep "^add blacklist-v4 " | sed 's/add blacklist-v4/add GOVIPS/' | while read line; do
    ipset $line 2>/dev/null || true
done

iptables -N GOVBLOCK 2>/dev/null || true
iptables -I INPUT 1 -j GOVBLOCK
iptables -I GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
ipset save > /etc/ipset.conf
netfilter-persistent save

echo "=== Шаг 6. Настройка sysctl ==="
cat << EOF > /etc/sysctl.d/99-telemt-network.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
EOF
sysctl --system

echo "=== Шаг 7. Установка веб-интерфейса через оригинальный инсталлятор ==="
curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh -o /tmp/panel_install.sh

sed -i 's/read -p "Telemt API URL .*/API_URL="http:\/\/127.0.0.1:9091"/' /tmp/panel_install.sh
sed -i 's/read -p "Telemt API auth header .*/AUTH_HEADER=""/' /tmp/panel_install.sh

bash /tmp/panel_install.sh

rm -f /etc/nginx/conf.d/telemt-panel.conf
rm -f /etc/nginx/conf.d/telemt_panel.conf

if [ -f /etc/telemt-panel/config.toml ]; then
    sed -i 's|listen = .*|listen = "127.0.0.1:8080"|' /etc/telemt-panel/config.toml
    sed -i 's|base_path = .*|base_path = "/secret-panel"|' /etc/telemt-panel/config.toml
fi

chmod 775 /etc/telemt
chmod 664 /etc/telemt/telemt.toml
usermod -a -G telemt telemt-panel || true

systemctl daemon-reload
systemctl restart telemt-panel

echo "=== Шаг 4. Настройка конфигурации Nginx (Финальная перезапись) ==="
cat << EOF > /etc/nginx/sites-available/telemt
server {
    # Изменено: http2 перенесен в строку listen для совместимости с Nginx 1.24 в Ubuntu 24.04
    listen 127.0.0.1:8443 ssl http2;
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

# Запускаем очищенный Nginx
systemctl restart nginx

echo "=== Шаг 8. Настройка iptables ТСПУ ==="
iptables -t mangle -A OUTPUT -p tcp --sport 443 --tcp-flags SYN,ACK SYN,ACK -j TCPMSS --set-mss 96
iptables -I OUTPUT -p tcp --sport 443 --tcp-flags SYN,ACK SYN,ACK -m limit --limit 1/sec --limit-burst 1 -j DROP
iptables -A INPUT -p tcp --dport 443 --syn -m recent --name mtproto --rcheck --seconds 1 -j DROP
iptables -A INPUT -p tcp --dport 443 --syn -m recent --name mtproto --set -j ACCEPT

netfilter-persistent save
iptables-save > /etc/iptables/rules.v4

SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "IP_SERVER")
HEX_DOMAIN=$(echo -n "$DOMAIN" | xxd -p | tr -d '\n')

echo ""
echo "=============================================================================="
echo "                       УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА                            "
echo "=============================================================================="
echo ""
echo "--- ДАННЫЕ ДЛЯ АДМИНИСТРИРОВАНИЯ ---"
echo "Домен сервера:          ${DOMAIN}"
echo "Внешний IP сервера:     ${SERVER_IP}"
echo "Используемый секрет:    ${HEX_SECRET}"
echo "Панель управления:      https://${DOMAIN}/secret-panel"
echo "Дефолтный логин/пароль: admin / (тот, что вы ввели в инсталляторе панели)"
echo "Управление службами:    systemctl status telemt nginx telemt-panel"
echo ""
echo "--- СТРОКА ПОДКЛЮЧЕНИЯ ДЛЯ ТЕЛЕГРАМ (FakeTLS) ---"
echo "tg://proxy?server=${SERVER_IP}&port=443&secret=ee${HEX_SECRET}${HEX_DOMAIN}"
echo ""
echo "Альтернативная ссылка:"
echo "https://t.me/proxy?server=${SERVER_IP}&port=443&secret=ee${HEX_SECRET}${HEX_DOMAIN}"
echo "=============================================================================="
