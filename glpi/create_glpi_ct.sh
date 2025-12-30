#!/usr/bin/env bash

# ============================================================
# CONFIGURAÇÃO PRINCIPAL - VARIÁVEIS
# ============================================================

# CT CONFIG
CT_ID=999                     # ID do container
IP_ADDR="192.168.0.17/24"                # IP do container com /24 ou dhcp
GATEWAY="192.168.0.254"         # Gateway da rede
CT_NAME="DEV-GLPI"   # Nome do container no Proxmox
HOSTNAME="$CT_NAME"       # Hostname interno do Ubuntu
PASSWORD="admin"              # Senha root do container
MEMORY=2048
CORES=2
DISK_SIZE=8
BRIDGE="vmbr0"
STORAGE="ZFS-PRX-01"

# GLPI CONFIG
GLPI_VERSION="11.0.2"               # "" = última versão, ou defina algo como "10.0.5"
GLPI_DB="glpi"
GLPI_DB_USER="glpi"
GLPI_DB_PASS="YourStrongPassword"

# MariaDB root
DB_ROOT_PASS="adminMariaDB"

# LOCALE/TIMEZONE
TIMEZONE="Europe/Lisbon"
LOCALE="pt_PT.UTF-8"

# TEMPLATE
TEMPLATE="ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"

# ============================================================
# CORES E LOGS
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
abort()    { error "$1"; exit 1; }

# ============================================================
# VERIFICAR TEMPLATE
# ============================================================
section "Verificando template"
[[ ! -f "$TEMPLATE_PATH" ]] && abort "Template não encontrado: $TEMPLATE_PATH"
log "Template encontrado: $TEMPLATE_PATH"

# ============================================================
# FUNÇÕES
# ============================================================

create_container() {
    section "Criando CT: ${CT_NAME}"

    # Verifica se o CT_ID já existe
    if pct status "$CT_ID" &>/dev/null; then
        abort "Container CT_ID $CT_ID já existe!"
    fi
   # Criação do container
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

    # Inicia o container
    pct start $CT_ID || abort "Falha ao iniciar o CT."
    sleep 5
    log "Container criado e iniciado com sucesso."

    # Habilitar login root via SSH
    pct exec "$CT_ID" -- bash -c "
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
" || warn "Falha ao configurar SSH root"
    log "Login SSH remoto do root habilitado."
}

check_internet_and_update() {
    section "Verificando conexão com a internet (Ubuntu)"

    # Tenta pingar 8.8.8.8 até funcionar
    until pct exec "$CT_ID" -- bash -c "ping -c 1 8.8.8.8 &>/dev/null"; do
        warn "Sem conexão de internet. Tentando novamente em 10 segundos..."
        sleep 10
    done

    log "Conexão de internet OK. Atualizando sistema Ubuntu..."

    pct exec "$CT_ID" -- bash -c "
export LANG='${LOCALE}'
export LC_ALL='${LOCALE}'
export DEBIAN_FRONTEND=noninteractive
apt update &&
apt full-upgrade -y &&
apt autoremove -y &&
apt clean
" || abort "Falha nos updates do Ubuntu."
    log "Sistema Ubuntu atualizado com sucesso."
}

configure_locale() {
    section "Configurando timezone e locale"
    pct exec "$CT_ID" -- bash -c "
export LANG='${LOCALE}'
export LANGUAGE='${LOCALE%%.*}:${LOCALE%%.*}'
export LC_ALL='${LOCALE}'
timedatectl set-timezone '${TIMEZONE}'
apt update
apt install -y locales tzdata
sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen '${LOCALE}'
update-locale LANG='${LOCALE}'
" || abort "Falha ao configurar locale."
    log "Timezone e locale configurados."
}


install_mariadb() {
    section "Instalando MariaDB"
    pct exec "$CT_ID" -- bash -c "
export LANG='${LOCALE}'
export LC_ALL='${LOCALE}'
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
CREATE DATABASE ${GLPI_DB};
CREATE USER '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASS}';
GRANT ALL PRIVILEGES ON ${GLPI_DB}.* TO '${GLPI_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
" || abort "Falha ao criar banco GLPI."
    log "Banco GLPI criado."
}

install_apache_php_glpi() {
    section "Instalando Apache, PHP e GLPI (via wget)"

    pct exec "$CT_ID" -- bash -c "
# Passar variável para dentro do container
GLPI_VERSION='${GLPI_VERSION}'
export LANG='${LOCALE}'
export LC_ALL='${LOCALE}'
apt update
apt install -y apache2 php8.4 php8.4-fpm libapache2-mod-php8.4 \
php8.4-mysql php8.4-curl php8.4-gd php8.4-intl php8.4-ldap \
php8.4-xml php8.4-bz2 php8.4-zip php8.4-cli php8.4-mbstring php8.4-apcu \
php8.4-imap php8.4-gmp php8.4-bcmath php8.4-xmlrpc php8.4-opcache wget tar jq curl

# Obter versão do GLPI
if [[ -z \"\$GLPI_VERSION\" ]]; then
    GLPI_VERSION=\$(wget -qO- https://api.github.com/repos/glpi-project/glpi/releases/latest | jq -r '.tag_name')
    echo '[INFO] Usando última versão do GLPI:' \$GLPI_VERSION
else
    echo '[INFO] Usando versão definida do GLPI:' \$GLPI_VERSION
fi

# Diretórios
GLPI_PARENT_DIR='/var/www'
GLPI_DIR=\"\$GLPI_PARENT_DIR/glpi\"
TMP_DIR=\"/tmp/glpi_extracted\"

# Download e extração
wget https://github.com/glpi-project/glpi/releases/download/\$GLPI_VERSION/glpi-\$GLPI_VERSION.tgz
mkdir -p \$TMP_DIR
tar -xvzf glpi-\$GLPI_VERSION.tgz -C \$TMP_DIR
rm glpi-\$GLPI_VERSION.tgz

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

log "Apache, PHP e GLPI instalados (versão: ${GLPI_VERSION})."
}


a2ensite glpi.conf
a2dissite 000-default.conf
a2enmod rewrite
phpenmod apcu opcache
" || abort "Falha na instalação de Apache/PHP/GLPI"

log "Apache, PHP e GLPI instalados (versão: ${GLPI_VERSION})."
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
check_internet_and_update
install_mariadb
create_glpi_db
install_apache_php_glpi
restart_services

section "PROCESSO FINALIZADO"
log "CT ${CT_NAME} criado e configurado com sucesso!"
pct status $CT_ID
