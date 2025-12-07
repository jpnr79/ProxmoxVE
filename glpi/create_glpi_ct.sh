#!/usr/bin/env bash

# ============================================================
#  COLORS
# ============================================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

log()      { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()     { echo -e "${YELLOW}[AVISO]${RESET} $*"; }
error()    { echo -e "${RED}[ERRO]${RESET} $*" >&2; }
section()  { echo -e "\n${BLUE}==== $* ====${RESET}\n"; }

# ============================================================
#  FUNÇÃO DE ABORTO
# ============================================================
abort() {
    error "$1"
    exit 1
}

# ============================================================
#  INPUT DO USUÁRIO
# ============================================================
section "Entrada de dados"

read -p "CT_ID (ex: 200): " CT_ID
read -p "IP (ex: 192.168.1.50/24 ou dhcp): " IP_ADDR
read -p "Gateway (ex: 192.168.1.1): " GATEWAY

[[ -z "$CT_ID" ]] && abort "CT_ID inválido."
[[ -z "$IP_ADDR" ]] && abort "IP inválido."
[[ -z "$GATEWAY" ]] && abort "Gateway inválido."

# ============================================================
#  VARIÁVEIS FIXAS
# ============================================================
HOSTNAME="ubuntu-${CT_ID}"
PASSWORD="admin"
MEMORY="2048"
CORES="2"
DISK_SIZE="8"
BRIDGE="vmbr0"

DB_ROOT_PASS="adminMaria!"
GLPI_DB_PASS="YourStrongPassword"

TIMEZONE="Europe/Lisbon"
LOCALE="pt_PT.UTF-8"

TEMPLATE="ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"

STORAGE="local-lvm"

# ============================================================
#  VERIFICAR TEMPLATE
# ============================================================
section "Verificando template"
[[ ! -f "$TEMPLATE_PATH" ]] && abort "Template não encontrado: $TEMPLATE_PATH"
log "Template encontrado."

# ============================================================
#  FUNÇÃO CRIAR CONTAINER
# ============================================================
create_container() {
    section "Criando CT"

    pct create $CT_ID "$TEMPLATE_PATH" \
        --hostname "$HOSTNAME" \
        --password "$PASSWORD" \
        --cores $CORES \
        --memory $MEMORY \
        --rootfs "${STORAGE}:${DISK_SIZE}" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_ADDR},gw=${GATEWAY}" \
        --unprivileged 1 \
        --features nesting=1 \
        --swap 512 || abort "Falha ao criar o CT."

    log "Container criado com sucesso."

    pct start $CT_ID || abort "Falha ao iniciar o CT."
    sleep 5
}

# ============================================================
#  TIMEZONE & LOCALE
# ============================================================
configure_locale() {
    section "Configurando timezone e locale"

    pct exec "$CT_ID" -- bash -c "
        timedatectl set-timezone '${TIMEZONE}'
        apt update
        apt install -y locales
        sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen
        locale-gen '${LOCALE}'
        update-locale LANG='${LOCALE}'
    " || abort "Falha ao configurar locale."

    log "Timezone e locale configurados."
}

# ============================================================
#  UPDATE DO SISTEMA
# ============================================================
update_system() {
    section "Atualizando sistema"

    pct exec "$CT_ID" -- bash -c "
        apt update &&
        apt full-upgrade -y &&
        apt autoremove -y &&
        apt clean
    " || abort "Falha nos updates."

    log "Sistema atualizado."
}

# ============================================================
#  INSTALAR E CONFIGURAR MARIADB
# ============================================================
install_mariadb() {
    section "Instalando MariaDB"

    pct exec "$CT_ID" -- bash -c "apt install -y mariadb-server" \
        || abort "Falha ao instalar MariaDB."

    section "Configurando MariaDB"

    pct exec "$CT_ID" -- bash -c "
        mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;\"
    " || abort "Falha ao definir senha root."

    pct exec "$CT_ID" -- bash -c "
        mysql -u root -p\"${DB_ROOT_PASS}\" <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    " || abort "Falha na configuração de segurança MariaDB."

    log "MariaDB instalado e seguro."
}

# ============================================================
#  CRIAR DB DO GLPI
# ============================================================
create_glpi_db() {
    section "Criando banco GLPI"

    pct exec "$CT_ID" -- bash -c "
        mysql -u root -p\"${DB_ROOT_PASS}\" <<EOF
CREATE DATABASE glpidb;
CREATE USER 'glpiuser'@'localhost' IDENTIFIED BY '${GLPI_DB_PASS}';
GRANT ALL PRIVILEGES ON glpidb.* TO 'glpiuser'@'localhost';
FLUSH PRIVILEGES;
EOF
    " || abort "Falha ao criar banco GLPI."

    log "Banco GLPI criado."
}

# ============================================================
#  APACHE + PHP 8.4
# ============================================================
install_apache_php() {
    section "Instalando Apache + PHP 8.4"

    pct exec "$CT_ID" -- bash -c "
apt update && apt install -y apache2 php8.4 php8.4-fpm libapache2-mod-php8.4 \
php8.4-mysql php8.4-curl php8.4-gd php8.4-intl php8.4-ldap \
php8.4-xml php8.4-bz2 php8.4-zip php8.4-cli apache2 apache2-bin apache2-utils

# Ativar módulos Apache
a2enmod proxy_fcgi setenvif
a2enconf php8.4-fpm
a2enmod rewrite

# Reiniciar Apache
systemctl restart apache2
" || abort "Falha ao instalar Apache/PHP."

    log "Apache e PHP instalados."
}

# ============================================================
#  GLPI
# ============================================================
install_glpi() {
    section "Instalando GLPI"

    pct exec "$CT_ID" -- bash -c "
GLPI_DIR=\"/var/www/html/glpi\"

# Garantir ferramentas essenciais
apt update
apt install -y wget curl jq tar

# Obter URL da última release estável no GitHub
API_URL=\"https://api.github.com/repos/glpi-project/glpi/releases/latest\"
DOWNLOAD_URL=\$(curl -sL \$API_URL | jq -r .tarball_url)

if [ -z \"\$DOWNLOAD_URL\" ]; then
  echo \"[ERRO] Não foi possível obter a URL da última release.\" >&2
  exit 1
fi

# Baixar e extrair
wget -O /tmp/glpi-latest.tar.gz \$DOWNLOAD_URL
mkdir -p /var/www/html
tar -xzf /tmp/glpi-latest.tar.gz -C /var/www/html/
rm -f /tmp/glpi-latest.tar.gz

# Renomear diretório extraído para glpi
EXTRACTED_DIR=\$(ls /var/www/html | grep glpi | head -1)
mv \"/var/www/html/\$EXTRACTED_DIR\" \"\$GLPI_DIR\" 2>/dev/null || true

# Ajustar permissões
chown -R www-data:www-data \$GLPI_DIR
chmod -R 755 \$GLPI_DIR

# VirtualHost Apache
VHOST_CONF=\"/etc/apache2/sites-available/glpi.conf\"
cat <<EOF > \$VHOST_CONF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot \$GLPI_DIR/public
    <Directory \$GLPI_DIR/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Habilitar site e reiniciar serviços
a2ensite glpi.conf
a2dissite 000-default.conf
service apache2 restart
service php8.4-fpm restart
" || abort "Falha ao instalar GLPI."

    log "GLPI instalado com sucesso."
}


# ============================================================
#  EXECUÇÃO EM ORDEM
# ============================================================
create_container
configure_locale
update_system
install_mariadb
create_glpi_db
install_apache_php
install_glpi

section "PROCESSO FINALIZADO"
log "CT ${CT_ID} criado e configurado com sucesso!"
pct status $CT_ID
