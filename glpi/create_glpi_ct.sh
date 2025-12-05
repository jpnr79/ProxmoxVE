#!/usr/bin/env bash
set -e

# VARIÁVEIS - AJUSTE AQUI
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

# DIRETÓRIOS PERSISTENTES PARA PLUGINS/MARKETPLACE
PLUGINS_MP="/var/lib/vz/glpi-plugins-${CTID}"
MARKETPLACE_MP="/var/lib/vz/glpi-marketplace-${CTID}"

log() { echo "[PROXMOX-GLPI] $*"; }

# Verifica CTID
if pct status $CTID >/dev/null 2>&1; then
  log "ERRO: CTID $CTID já existe."
  exit 1
fi

log "Criando CT $CTID com persistência plugins/marketplace..."
pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --memory $RAM \
  --cores $CPUS \
  --rootfs $STORAGE:$DISK \
  --net0 name=eth0,bridge=$NETBRIDGE,ipaddr=$IP,gw=$GATEWAY \
  --arch amd64 \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1 \
  --startup start=1,order=1,up=60s

pct start $CTID
sleep 30

# CRIA DIRETÓRIOS PERSISTENTES NO HOST
mkdir -p "$PLUGINS_MP" "$MARKETPLACE_MP" "/var/lib/vz/dump/glpi-backups-${CTID}"

# BIND MOUNTS PARA PLUGINS E MARKETPLACE
pct set $CTID -mp0 "$PLUGINS_MP,mp=/var/www/glpi/plugins"
pct set $CTID -mp1 "$MARKETPLACE_MP,mp=/var/www/glpi/marketplace"

log "Bind mounts criados:"
log "- Plugins: $PLUGINS_MP → /var/www/glpi/plugins"
log "- Marketplace: $MARKETPLACE_MP → /var/www/glpi/marketplace"

# Script interno otimizado
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

# Atualiza sistema
apt update && apt -y full-upgrade
apt -y install sudo curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common

# Pacotes principais
apt -y install apache2 apache2-utils mariadb-server mariadb-client redis-server

svc enable apache2 mariadb redis-server
svc start apache2 mariadb redis-server

# TUNING MARIADB GLPI
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

# DB GLPI
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${GLPI_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASS}';
GRANT ALL PRIVILEGES ON ${GLPI_DB_NAME}.* TO '${GLPI_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# PHP + extensões
apt -y install php${PHP_VER}-fpm php${PHP_VER}-mysql php${PHP_VER}-curl php${PHP_VER}-gd php${PHP_VER}-intl \\
  php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-apcu php${PHP_VER}-ldap \\
  php${PHP_VER}-imap php${PHP_VER}-bcmath php${PHP_VER}-soap php${PHP_VER}-redis

PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i 's/memory_limit.*/memory_limit = 512M/' $PHP_INI
sed -i 's/upload_max_filesize.*/upload_max_filesize = 128M/' $PHP_INI
sed -i 's/post_max_size.*/post_max_size = 128M/' $PHP_INI
sed -i 's/max_execution_time.*/max_execution_time = 300/' $PHP_INI
sed -i "s~;date.timezone.*~date.timezone = ${TZ}~" $PHP_INI

svc restart php${PHP_VER}-fpm

# REDIS otimizado
sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf
sed -i 's/^# maxmemory <bytes>/maxmemory 512mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
sed -i 's/^save 900 1/# save 900 1/' /etc/redis/redis.conf
svc restart redis-server

# ✅ IMPORTANTE: Inicializa diretórios persistentes com permissões corretas
mkdir -p ${GLPI_DIR}/plugins ${GLPI_DIR}/marketplace
chown -R www-data:www-data ${GLPI_DIR}/plugins ${GLPI_DIR}/marketplace
chmod -R 755 ${GLPI_DIR}/plugins ${GLPI_DIR}/marketplace

# Instala GLPI
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

# SCRIPTS BACKUP/UPDATE (PRESERVA PLUGINS/MARKETPLACE)
mkdir -p /backup/glpi

cat >/root/scripts/backup_glpi.sh <<'EOS'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M)
BACKUP_DIR="/backup/glpi"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="SenhaFort3!"

# Backup arquivos CORE (exclui plugins/marketplace persistentes)
tar czf ${BACKUP_DIR}/glpi_core_${DATE}.tar.gz \\
  --exclude=${GLPI_DIR}/plugins \\
  --exclude=${GLPI_DIR}/marketplace \\
  -C /var/www glpi

# Backup DB
mysqldump -u${DB_USER} -p${DB_PASS} ${DB_NAME} > ${BACKUP_DIR}/glpi_db_${DATE}.sql

# Backup plugins/marketplace (separado)
tar czf ${BACKUP_DIR}/glpi_plugins_${DATE}.tar.gz -C /var/www/glpi plugins marketplace

find ${BACKUP_DIR} -type f -mtime +7 -delete
echo "Backup concluído $(ls -la ${BACKUP_DIR} | tail -1)"
EOS

cat >/root/scripts/update_glpi.sh <<'EOS'
#!/bin/bash
GLPI_VERSION="11.0.1"  # AJUSTE AQUI A NOVA VERSÃO
GLPI_DIR="/var/www/glpi"
BACKUP_DIR="/backup/glpi"

echo "=== UPDATE GLPI ${GLPI_VERSION} ==="
echo "1. Backup..."
/root/scripts/backup_glpi.sh

echo "2. Download nova versão..."
cd /tmp
wget -O glpi_new.tgz "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
tar xzf glpi_new.tgz

echo "3. Backup config atual..."
cp -r ${GLPI_DIR}/config ${BACKUP_DIR}/config_backup_$(date +%Y%m%d)

echo "4. Atualiza CORE (PRESERVA plugins/marketplace)..."
rsync -av --delete --exclude=plugins --exclude=marketplace --exclude=config glpi/ ${GLPI_DIR}/
chown -R www-data:www-data ${GLPI_DIR}
chmod -R 755 ${GLPI_DIR}

echo "5. Restart services..."
service apache2 restart
service php8.3-fpm restart

echo "✅ GLPI atualizado para ${GLPI_VERSION}"
echo "Plugins/marketplace PRESERVADOS em bind mounts"
echo "Verifique: http://$(hostname -I | awk '{print $1}')"
EOS

chmod +x /root/scripts/backup_glpi.sh /root/scripts/update_glpi.sh
mkdir -p /root/scripts

# CRON: backup diário 2AM, update semanal DOM 3AM
echo "0 2 * * * root /root/scripts/backup_glpi.sh" >> /etc/crontab
echo "0 3 * * 0 root /root/scripts/update_glpi.sh" >> /etc/crontab

touch /etc/.pve-ignore.hosts

log "GLPI ${GLPI_VERSION} pronto com PERSISTÊNCIA!"
log "Plugins: /var/lib/vz/glpi-plugins-${CTID}"
log "Marketplace: /var/lib/vz/glpi-marketplace-${CTID}"
EOF

chmod +x /tmp/glpi_install.sh
pct exec $CTID -- bash /tmp/glpi_install.sh

log "=============================================="
log "✅ CT $CTID GLPI 11 PRONTO com PERSISTÊNCIA!"
log "🌐 IP: $(echo $IP | cut -d/ -f1)"
log "📂 Plugins: $PLUGINS_MP"
log "📂 Marketplace: $MARKETPLACE_MP"
log "💾 Backup: /var/lib/vz/dump/glpi-backups-${CTID}"
log "🚀 Acesse: http://$(echo $IP | cut -d/ -f1)/"
log "📋 DB: glpi/glpi/SenhaFort3!"
log "🔄 Updates PRESERVAM plugins/marketplace"
log "=============================================="
