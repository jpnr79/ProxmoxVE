#!/usr/bin/env bash

# ============================================================
# COLORS
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

abort() { error "$1"; exit 1; }

# ============================================================
# INPUT DO USUÁRIO
# ============================================================
section "Entrada de dados"
read -p "CT_ID (ex: 200): " CT_ID
read -p "IP (ex: 192.168.1.50/24 ou dhcp): " IP_ADDR
read -p "Gateway (ex: 192.168.1.1): " GATEWAY

[[ -z "$CT_ID" ]] && abort "CT_ID inválido."
[[ -z "$IP_ADDR" ]] && abort "IP inválido."
[[ -z "$GATEWAY" ]] && abort "Gateway inválido."

# ============================================================
# VARIÁVEIS FIXAS
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
# VERIFICAR TEMPLATE
# ============================================================
section "Verificando template"
[[ ! -f "$TEMPLATE_PATH" ]] && abort "Template não encontrado: $TEMPLATE_PATH"
log "Template encontrado."

# ============================================================
# FUNÇÕES
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

    pct start $CT_ID || abort "Falha ao iniciar o CT."
    sleep 5
    log "Container criado e iniciado com sucesso."
}

configure_locale() {
    section "Configurando timezone e locale"
    pct exec "$CT_ID" -- bash -c "
timedatectl set-timezone '${TIMEZONE}'
apt update
apt install -y locales tzdata
sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen '${LOCALE}'
update-locale LANG='${LOCALE}'
" || abort "Falha ao configurar locale."
    log "Timezone e locale configurados."
}

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

install_mariadb() {
    section "Instalando MariaDB"
    pct exec "$CT_ID" -- bash -c "
apt install -y mariadb-server mariadb-client
" || abort "Falha ao instalar MariaDB."

    section "Configurando MariaDB"
    pct exec "$CT_ID" -- bash -c "
mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;\" 
mysql -u root -p\"${DB_ROOT_PASS}\" <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

if command -v mysql_tzinfo_to_sql >/dev/null 2>&1; then
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p\"${DB_ROOT_PASS}\" mysql
else
    echo '[AVISO] mysql_tzinfo_to_sql não encontrado, ignorando timezone.'
fi
" || abort "Falha na configuração de MariaDB."
    log "MariaDB instalado, seguro e timezone carregado."
}

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

install_apache_php_glpi() {
    section "Instalando Apache, PHP e GLPI (última versão via wget)"

    pct exec "$CT_ID" -- bash -c "
apt update
apt install -y apache2 php8.4 php8.4-fpm libapache2-mod-php8.4 \
php8.4-mysql php8.4-curl php8.4-gd php8.4-intl php8.4-ldap \
php8.4-xml php8.4-bz2 php8.4-zip php8.4-cli php8.4-mbstring php8.4-apcu \
php8.4-imap php8.4-gmp php8.4-bcmath php8.4-xmlrpc php8.4-opcache wget tar jq curl

# Obter última versão GLPI
LATEST_TAG=\$(wget -qO- https://api.github.com/repos/glpi-project/glpi/releases/latest | jq -r '.tag_name')
echo '[INFO] Última versão do GLPI:' \$LATEST_TAG

# Diretórios
GLPI_PARENT_DIR='/var/www'
GLPI_DIR=\"\$GLPI_PARENT_DIR/glpi\"
TMP_DIR=\"/tmp/glpi_extracted\"

# Download e extração
wget -O glpi-\$LATEST_TAG.tgz https://github.com/glpi-project/glpi/releases/download/\$LATEST_TAG/glpi-\$LATEST_TAG.tgz
mkdir -p \$TMP_DIR
tar -xzf glpi-\$LATEST_TAG.tgz -C \$TMP_DIR
rm glpi-\$LATEST_TAG.tgz

# Obter o nome real da pasta extraída
EXTRACTED_DIR=\$(ls \$TMP_DIR | head -n1)

# Remover antigo GLPI e mover novo
rm -rf /var/www/glpi
mv \"\$TMP_DIR/\$EXTRACTED_DIR\" /var/www/glpi
rmdir \$TMP_DIR

# Permissões
chown -R www-data:www-data \$GLPI_DIR
find \$GLPI_DIR -type d -exec chmod 755 {} \;
find \$GLPI_DIR -type f -exec chmod 644 {} \;

# Configuração Apache
VHOST_CONF='/etc/apache2/sites-available/glpi.conf'
cat <<EOF > \$VHOST_CONF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot \$GLPI_DIR/public
    <Directory \$GLPI_DIR/public>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted

        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/glpi-error.log
    CustomLog \${APACHE_LOG_DIR}/glpi-access.log combined
</VirtualHost>
EOF

a2ensite glpi.conf
a2dissite 000-default.conf
a2enmod rewrite
phpenmod apcu opcache
" || abort "Falha na instalação de Apache/PHP/GLPI"

log "Apache, PHP e GLPI instalados (última versão)."
}

restart_services() {
    section "Reiniciando Apache e PHP"
    pct exec "$CT_ID" -- bash -c "
systemctl restart php8.4-fpm
systemctl restart apache2
" || abort "Falha ao reiniciar serviços"
log "Serviços reiniciados com sucesso."
}

# ============================================================
# EXECUÇÃO EM ORDEM
# ============================================================
create_container
configure_locale
update_system
install_mariadb
create_glpi_db
install_apache_php_glpi
restart_services

section "PROCESSO FINALIZADO"
log "CT ${CT_ID} criado e configurado com sucesso!"
pct status $CT_ID
