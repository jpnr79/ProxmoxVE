#!/usr/bin/env bash
set -e
# ===========================================
# CONFIGURAÇÃO PRINCIPAL DO CONTAINER
# ===========================================
CTID=199
HOSTNAME="SRV-GLPI"
IP="192.168.0.199/24"
GATEWAY="192.168.0.1"
RAM=4096
CPUS=2
DISK=40
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-lvm"
NETBRIDGE="vmbr0"
GLPI_DB_PASS="SenhaFort3!"
CT_ROOT_PASS="admin"
# 3 DIRETÓRIOS PERSISTENTES
PLUGINS_MP="/var/lib/vz/glpi-plugins-${CTID}"
MARKETPLACE_MP="/var/lib/vz/glpi-marketplace-${CTID}"
FILES_MP="/var/lib/vz/glpi-files-${CTID}"

log() { echo "[PROXMOX-GLPI] $*"; }
# ===========================================
# CRIAÇÃO DO CONTAINER
# ===========================================
if pct status $CTID >/dev/null 2>&1; then
  log "ERRO: CTID $CTID já existe."
  exit 1
fi

log "Criando CT $CTID..."
pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --memory $RAM \
  --cores $CPUS \
  --rootfs $STORAGE:$DISK \
  --arch amd64 \
  --ostype debian \
  --unprivileged 0 \
  --features nesting=1

log "Configurando rede..."
pct set $CTID -net0 "name=eth0,bridge=$NETBRIDGE,ip=$IP,gw=$GATEWAY"
pct set $CTID -onboot 1



log "Iniciando CT..."
pct start $CTID
sleep 15
# ✅ SENHA ROOT DEFINIDA AQUI (método correto)
pct exec $CTID -- passwd root <<< "$CT_ROOT_PASS"$'\n'"$CT_ROOT_PASS"
log "🔑 Senha root definida: $CT_ROOT_PASS"
log "Configurando DNS..."
pct exec $CTID -- bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
pct exec $CTID -- bash -c "echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"

log "Testando DNS..."
if ! nslookup google.com >/dev/null 2>&1; then
  log "Configurando DNS manual..."
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf
fi

# ===========================================
# CONFIGURAÇÃO DE DIRETÓRIOS PERSISTENTES
# ===========================================
mkdir -p "$PLUGINS_MP" "$MARKETPLACE_MP" "$FILES_MP" "/var/lib/vz/dump/glpi-backups-${CTID}"

pct set $CTID -mp0 "$PLUGINS_MP,mp=/var/www/glpi/plugins"
pct set $CTID -mp1 "$MARKETPLACE_MP,mp=/var/www/glpi/marketplace"  
pct set $CTID -mp2 "$FILES_MP,mp=/var/www/glpi/files"

log "✅ Bind mounts criados:"
log "- Plugins:     $PLUGINS_MP → /var/www/glpi/plugins"
log "- Marketplace: $MARKETPLACE_MP → /var/www/glpi/marketplace"
log "- Files:       $FILES_MP → /var/www/glpi/files"

# ===========================================
# INSTALAÇÃO AUTOMÁTICA DO GLPI
# ===========================================
cat > /tmp/glpi_install.sh <<'EOF'
#!/usr/bin/env bash
set -e
GLPI_VERSION="11.0.4"
GLPI_DB_NAME="glpi"
GLPI_DB_USER="glpi"
GLPI_DB_PASS="SenhaFort3!"
GLPI_DIR="/var/www/glpi"
PHP_VER="8.4"
TZ="Europe/Lisbon"
log() { echo "[GLPI-CT] $*"; }

svc() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$1" "$2" 2>/dev/null || service "$2" "$1"
  else
    service "$2" "$1"
  fi
}

log "Atualizando sistema e pacotes base..."
apt update && apt -y full-upgrade
apt -y install sudo curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common

log "Configurando repositório PHP 8.4..."
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] https://packages.sury.org/php/ \$(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list

apt update
apt -y install apache2 apache2-utils mariadb-server mariadb-client redis-server


svc enable apache2 mariadb redis-server
svc start apache2 mariadb redis-server

# MariaDB tuning
cat >/etc/mysql/mariadb.conf.d/60-glpi.cnf <<EOM
[mysqld]
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_log_buffer_size = 64M
innodb_flush_log_at_trx_commit = 2
max_connections = 200
table_open_cache = 4096
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
query_cache_type = 0
EOM

svc restart mariadb

mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${GLPI_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASS}';
GRANT ALL PRIVILEGES ON ${GLPI_DB_NAME}.* TO '${GLPI_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

log "Instalando PHP 8.4 + extensões..."
apt -y install php8.4-fpm php8.4-mysql php8.4-curl php8.4-gd php8.4-intl \
  php8.4-mbstring php8.4-xml php8.4-zip php8.4-apcu php8.4-ldap \
  php8.4-imap php8.4-bcmath php8.4-soap php8.4-redis
log "Usando PHP versão: $PHP_VER"

# ✅ AGORA configura php.ini (caminho corrigido)
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i 's/memory_limit.*/memory_limit = 512M/' "$PHP_INI"
sed -i 's/upload_max_filesize.*/upload_max_filesize = 128M/' "$PHP_INI"
sed -i 's/post_max_size.*/post_max_size = 128M/' "$PHP_INI"
sed -i 's/max_execution_time.*/max_execution_time = 300/' "$PHP_INI"
sed -i "s~;date.timezone.*~date.timezone = ${TZ}~" "$PHP_INI"

svc restart php${PHP_VER}-fpm

# Redis
sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf
sed -i 's/^# maxmemory <bytes>/maxmemory 512mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
sed -i 's/^save 900 1/# save 900 1/' /etc/redis/redis.conf
svc restart redis-server

log "Inicializando diretórios persistentes..."
mkdir -p ${GLPI_DIR}/plugins ${GLPI_DIR}/marketplace ${GLPI_DIR}/files
chown -R www-data:www-data ${GLPI_DIR}/plugins ${GLPI_DIR}/marketplace ${GLPI_DIR}/files
chmod -R 755 ${GLPI_DIR}/plugins ${GLPI_DIR}/marketplace ${GLPI_DIR}/files

# GLPI
mkdir -p /tmp/glpi
cd /tmp/glpi
wget -O glpi.tgz "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
tar xzf glpi.tgz
rm -rf ${GLPI_DIR}
mv glpi ${GLPI_DIR}
chown -R www-data:www-data ${GLPI_DIR}
chmod -R 755 ${GLPI_DIR}

# VirtualHost
cat >/etc/apache2/sites-available/glpi.conf <<EOM
<VirtualHost *:80>
    ServerName glpi11.local
    DocumentRoot ${GLPI_DIR}/public
    <Directory ${GLPI_DIR}/public>
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOM

a2dissite 000-default.conf
a2ensite glpi.conf
a2enmod proxy proxy_fcgi rewrite
svc restart apache2

# SCRIPTS BACKUP/UPDATE
mkdir -p /backup/glpi /root/scripts

cat >/root/scripts/backup_glpi.sh <<'EOS'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M)
BACKUP_DIR="/backup/glpi"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="SenhaFort3!"
GLPI_DIR="/var/www/glpi"

tar czf ${BACKUP_DIR}/glpi_core_${DATE}.tar.gz \
  --exclude=${GLPI_DIR}/plugins \
  --exclude=${GLPI_DIR}/marketplace \
  --exclude=${GLPI_DIR}/files \
  -C /var/www glpi

mysqldump -u${DB_USER} -p${DB_PASS} ${DB_NAME} > ${BACKUP_DIR}/glpi_db_${DATE}.sql

tar czf ${BACKUP_DIR}/glpi_plugins_${DATE}.tar.gz -C ${GLPI_DIR} plugins marketplace
tar czf ${BACKUP_DIR}/glpi_files_${DATE}.tar.gz -C ${GLPI_DIR} files

find ${BACKUP_DIR} -type f -mtime +7 -delete
echo "✅ Backup completo: $(ls -la ${BACKUP_DIR} | tail -1)"
EOS

cat >/root/scripts/update_glpi.sh <<'EOS'
#!/bin/bash
GLPI_VERSION="11.0.4"
GLPI_DIR="/var/www/glpi"
BACKUP_DIR="/backup/glpi"

echo "=== UPDATE GLPI ${GLPI_VERSION} ==="
/root/scripts/backup_glpi.sh

cd /tmp
wget -O glpi_new.tgz "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
tar xzf glpi_new.tgz

cp -r ${GLPI_DIR}/config ${BACKUP_DIR}/config_backup_$(date +%Y%m%d)

rsync -av --delete \
  --exclude=plugins \
  --exclude=marketplace \
  --exclude=files \
  --exclude=config \
  glpi/ ${GLPI_DIR}/

chown -R www-data:www-data ${GLPI_DIR}
chmod -R 755 ${GLPI_DIR}

systemctl restart apache2 php8.4-fpm

echo "✅ GLPI ${GLPI_VERSION} atualizado!"
echo "🌐 http://$(hostname -I | awk '{print \$1}')"
EOS

chmod +x /root/scripts/backup_glpi.sh /root/scripts/update_glpi.sh
echo "0 2 * * * root /root/scripts/backup_glpi.sh" >> /etc/crontab
echo "0 3 * * 0 root /root/scripts/update_glpi.sh" >> /etc/crontab

touch /etc/.pve-ignore.hosts

log "GLPI ${GLPI_VERSION} com PHP 8.4 pronto!"
EOF

chmod +x /tmp/glpi_install.sh
pct exec $CTID -- bash /tmp/glpi_install.sh

log "=============================================="
log "✅ CT $CTID GLPI 11.0.4 - PHP 8.4 - 3 PERSISTÊNCIAS!"
log "🌐 http://$(echo $IP | cut -d/ -f1)/"
log "📂 Plugins: $PLUGINS_MP"
log "📂 Marketplace: $MARKETPLACE_MP" 
log "📂 Files: $FILES_MP"
log "💾 Backups: /var/lib/vz/dump/glpi-backups-${CTID}"
log "=============================================="
