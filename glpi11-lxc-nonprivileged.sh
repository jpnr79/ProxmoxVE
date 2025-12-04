#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

#### -------------------------
#### VARIÁVEIS (edite aqui)
#### -------------------------
CTID=210
TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.12-1_amd64.tar.zst" #Conforme CT baixado no gui
HOSTNAME="glpi-np"
PASSWORD="TroqueSenhaRootLXC!"
DISK="20" #GB
RAM="4096"         # MB
SWAP="1024"
CPUS="2"
BRIDGE="vmbr0"
IP_ADDR="192.168.1.75/24"
GW="192.168.1.1"

GLPI_VERSION="11.0.0"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="TroqueSenhaDB!"

PHP_VER="8.4"
REDIS_MEMORY="512mb"
APC_SHM="256M"
OPCACHE_MEM=256

# Host path para persistência dos arquivos do GLPI (será criado se não existir)
HOST_GLPI_FILES_DIR="/var/lib/glpi-files/$CTID"

# Backup
BACKUP_DIR="/opt/glpi-backup"
RETENTION_KEEP=15
REMOTE_BACKUP_COMMAND=""  # opcional

# Monitoring (opcional)
ZABBIX_SERVER=""

# LXC features (non-privileged)
UNPRIVILEGED=1
NESTING=1
FUSE=1
ROOTFS_STORAGE="local-lvm"

#### -------------------------
#### Funções utilitárias
#### -------------------------
echo "=== Iniciando: criação de LXC não-privilegiado para GLPI ==="

# Detectar base de subuid/subgid (ex: 100000)
detect_subid_base() {
  local base
  base="$(awk -F: '/^root:/{print $2; exit}' /etc/subuid || true)"
  if [[ -z "$base" ]]; then
    echo "100000"
  else
    echo "$base"
  fi
}

SUBUID_BASE=$(detect_subid_base)
SUBGID_BASE="$(awk -F: '/^root:/{print $2; exit}' /etc/subgid || echo "$SUBUID_BASE")"

echo "=> subuid base detectado: $SUBUID_BASE"
echo "=> subgid base detectado: $SUBGID_BASE"

# UIDs dentro do container: www-data = 33 (Debian). Mapado no host: base + 33
HOST_UID_WWW=$((SUBUID_BASE + 33))
HOST_GID_WWW=$((SUBGID_BASE + 33))

echo "=> host UID para www-data: $HOST_UID_WWW  GID: $HOST_GID_WWW"

#### -------------------------
#### Preparar diretório host para /var/www/glpi/files
#### -------------------------
echo "=> Criando diretório host para persistência de arquivos do GLPI: $HOST_GLPI_FILES_DIR"
mkdir -p "$HOST_GLPI_FILES_DIR"
chown "$HOST_UID_WWW:$HOST_GID_WWW" "$HOST_GLPI_FILES_DIR"
chmod 750 "$HOST_GLPI_FILES_DIR"

#### -------------------------
#### Criar LXC não-privilegiado com nesting + fuse e montar mp0
#### -------------------------
echo "=> Criando container LXC (non-privileged) CTID=$CTID ..."
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  --net0 name=eth0,bridge="$BRIDGE",ip="$IP_ADDR",gw="$GW" \
  --cores "$CPUS" \
  --memory "$RAM" \
  --swap "$SWAP" \
  --rootfs "${ROOTFS_STORAGE}:$DISK" \
  --unprivileged "$UNPRIVILEGED" \
  --features "nesting=${NESTING},fuse=${FUSE}" \
  --onboot 1

# montar host dir como mp0 no container (persistência de arquivos)
echo "=> Registrando mountpoint mp0 -> $HOST_GLPI_FILES_DIR (mp=/var/www/glpi/files)"
pct set "$CTID" -mp0 "${HOST_GLPI_FILES_DIR},mp=/var/www/glpi/files"

pct start "$CTID"
echo "=> Container iniciado."

#### -------------------------
#### Helper para executar comandos dentro do LXC
#### -------------------------
_exec() {
  pct exec "$CTID" -- bash -lc "$*"
}

#### -------------------------
#### Atualizar e instalar pacotes base dentro do container
#### -------------------------
echo "=> Atualizando container e instalando pacotes base..."
_exec "export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y
apt install -y apt-transport-https ca-certificates lsb-release wget gnupg software-properties-common unzip curl gnupg2"

#### -------------------------
#### Repositório PHP Sury e instalação de serviços
#### -------------------------
echo "=> Adicionando repositório PHP (Sury) e instalando Apache, PHP $PHP_VER, Redis e MariaDB..."
_exec "wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg || true
echo 'deb https://packages.sury.org/php/ $(lsb_release -sc) main' > /etc/apt/sources.list.d/php.list
apt update -y

apt install -y apache2 libapache2-mod-fcgid redis-server redis-tools mariadb-server fail2ban ufw
apt install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-common php${PHP_VER}-gd php${PHP_VER}-curl \
php${PHP_VER}-imap php${PHP_VER}-intl php${PHP_VER}-ldap php${PHP_VER}-mbstring php${PHP_VER}-mysql php${PHP_VER}-xml \
php${PHP_VER}-xmlrpc php${PHP_VER}-bz2 php${PHP_VER}-zip php${PHP_VER}-apcu php${PHP_VER}-redis php${PHP_VER}-opcache || true

# enable services
systemctl enable apache2 php${PHP_VER}-fpm redis-server mariadb || true
systemctl restart apache2 php${PHP_VER}-fpm redis-server mariadb || true
"

#### -------------------------
#### MariaDB: criar DB/usuario e tuning
#### -------------------------
echo "=> Configurando MariaDB (DB + tuning)..."
_exec "mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`$DB_NAME\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; \
GRANT ALL PRIVILEGES ON \\\`$DB_NAME\\\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;\""

_exec "cat > /etc/mysql/mariadb.conf.d/60-glpi.cnf <<'MYCNF'
[server]
innodb_buffer_pool_size = 1G
innodb_log_file_size = 512M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
max_connections = 200
query_cache_type = 0
query_cache_size = 0
tmp_table_size = 128M
max_heap_table_size = 128M
MYCNF

systemctl restart mariadb || true
"

#### -------------------------
#### PHP-FPM / OPcache / APCu tuning
#### -------------------------
echo "=> Aplicando tuning de PHP-FPM, OPcache e APCu..."
_exec "PHPVER=$PHP_VER
sed -i 's/^;*pm = .*/pm = ondemand/' /etc/php/\$PHPVER/fpm/pool.d/www.conf || true
sed -i 's/^;*pm.max_children = .*/pm.max_children = 40/' /etc/php/\$PHPVER/fpm/pool.d/www.conf || true
sed -i 's/^;*pm.max_requests = .*/pm.max_requests = 1500/' /etc/php/\$PHPVER/fpm/pool.d/www.conf || true
sed -i 's/^;*pm.process_idle_timeout = .*/pm.process_idle_timeout = 10s/' /etc/php/\$PHPVER/fpm/pool.d/www.conf || true

cat > /etc/php/\$PHPVER/mods-available/opcache.ini <<'OPC'
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=${OPCACHE_MEM}
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.save_comments=1
OPC

cat > /etc/php/\$PHPVER/mods-available/apcu.ini <<'APCU'
extension=apcu.so
apc.enabled=1
apc.shm_size=${APC_SHM}
apc.ttl=7200
apc.gc_ttl=3600
apc.entries_hint=4096
APCU

systemctl restart php\$PHPVER-fpm || true
"

#### -------------------------
#### Redis tuning (SuperCache)
#### -------------------------
echo "=> Configurando Redis (SuperCache) com $REDIS_MEMORY..."
_exec "sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf || true
sed -i 's/^# maxmemory .*/maxmemory $REDIS_MEMORY/' /etc/redis/redis.conf || true
sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lfu/' /etc/redis/redis.conf || true
sed -i 's/^appendonly .*/appendonly no/' /etc/redis/redis.conf || true
sed -i 's/^save .*/save \"\"/' /etc/redis/redis.conf || true
sed -i 's/^tcp-backlog .*/tcp-backlog 1024/' /etc/redis/redis.conf || true
sed -i 's/^timeout .*/timeout 0/' /etc/redis/redis.conf || true
systemctl restart redis-server || true
"

#### -------------------------
#### Baixar e instalar GLPI (persistência / permissões)
#### -------------------------
echo "=> Baixando e instalando GLPI $GLPI_VERSION..."
_exec "cd /opt
wget -q --show-progress https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz
tar -xzf glpi-${GLPI_VERSION}.tgz
mv -v glpi /var/www/glpi || true
# garantir que a pasta files do container seja o mountpoint mp0 apontando para host path
mkdir -p /var/www/glpi/files
chown -R www-data:www-data /var/www/glpi
find /var/www/glpi -type d -exec chmod 755 {} \;
find /var/www/glpi -type f -exec chmod 644 {} \;
"

#### -------------------------
#### Apache vhost (segurança + performance)
#### -------------------------
echo "=> Criando vhost Apache para GLPI..."
_exec "cat > /etc/apache2/sites-available/glpi.conf <<'APACHE'
<VirtualHost *:80>
    ServerName $HOSTNAME
    DocumentRoot /var/www/glpi/public

    <Directory /var/www/glpi/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory /var/www/glpi/config>
        Require all denied
    </Directory>

    <FilesMatch \.php$>
        SetHandler \"proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/\"
    </FilesMatch>

    Header always set X-Content-Type-Options \"nosniff\"
    Header always set X-Frame-Options \"SAMEORIGIN\"
    Header always set Referrer-Policy \"no-referrer-when-downgrade\"

    ErrorLog \${APACHE_LOG_DIR}/glpi-error.log
    CustomLog \${APACHE_LOG_DIR}/glpi-access.log combined
</VirtualHost>
APACHE

a2dissite 000-default || true
a2ensite glpi
a2enmod rewrite proxy_fcgi setenvif headers
systemctl reload apache2 || true
"

#### -------------------------
#### Configurar GLPI para usar Redis + APCu (local_define.php)
#### -------------------------
echo "=> Configurando GLPI para usar Redis+APCu..."
_exec "cat > /var/www/glpi/config/local_define.php <<'GLPI_CONF'
<?php
// Redis: sessions + cache
define('GLPI_CACHE_DRIVER', 'redis');
define('GLPI_CACHE_HOST', '127.0.0.1');
define('GLPI_CACHE_PORT', 6379);

// APCu: aceleração local
define('GLPI_APCU_ENABLED', true);
GLPI_CONF

chown www-data:www-data /var/www/glpi/config/local_define.php
chmod 640 /var/www/glpi/config/local_define.php || true
"

#### -------------------------
#### Backup automático (local) com rotação
#### -------------------------
echo "=> Instalando script de backup e cron (dir: $BACKUP_DIR ; keep: $RETENTION_KEEP)..."
_exec "mkdir -p $BACKUP_DIR

cat > /usr/local/bin/glpi-backup.sh <<'BACKUP'
#!/bin/bash
set -e
TS=\$(date +%Y%m%d-%H%M)
DST=\"$BACKUP_DIR/\$TS\"
mkdir -p \"\$DST\"

# compacta arquivos (exclui cache temporário)
tar -czf \"\$DST/glpi-files.tar.gz\" -C /var/www glpi --exclude='glpi/files/_cache' || true

# dump do DB
mysqldump $DB_NAME > \"\$DST/glpi.sql\" || true

chown -R root:root \"\$DST\"

# rotaciona
ls -1dt $BACKUP_DIR/* 2>/dev/null | tail -n +$((RETENTION_KEEP+1)) | xargs -r rm -rf

# remote optional
if [ -n \"${REMOTE_BACKUP_COMMAND}\" ]; then
  ${REMOTE_BACKUP_COMMAND}
fi
BACKUP

chmod +x /usr/local/bin/glpi-backup.sh

# Cron diário às 03:30
cat > /etc/cron.d/glpi-backup <<'CRON'
30 3 * * * root /usr/local/bin/glpi-backup.sh >> /var/log/glpi-backup.log 2>&1
CRON
"

#### -------------------------
#### Script de update seguro
#### -------------------------
echo "=> Criando script glpi-update.sh (update seguro)..."
_exec "cat > /usr/local/bin/glpi-update.sh <<'UPDATE'
#!/bin/bash
set -euo pipefail
if [ -z \"\${1:-}\" ]; then
  echo 'Uso: glpi-update.sh <versão>  (ex: glpi-update.sh 11.0.1)'
  exit 1
fi
VER=\$1
cd /opt
/usr/local/bin/glpi-backup.sh
wget -q https://github.com/glpi-project/glpi/releases/download/\$VER/glpi-\$VER.tgz
tar -xzf glpi-\$VER.tgz
rsync -a --exclude='config/*' --exclude='files/*' glpi/ /var/www/glpi/
chown -R www-data:www-data /var/www/glpi || true
rm -rf /var/www/glpi/files/_cache/* || true
systemctl restart apache2 php${PHP_VER}-fpm || true
echo \"GLPI updated to \$VER\"
UPDATE

chmod +x /usr/local/bin/glpi-update.sh
"

#### -------------------------
#### Hardening básico: UFW + Fail2Ban
#### -------------------------
echo "=> Aplicando UFW + Fail2Ban (baseline)..."
_exec "ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable || true

cat > /etc/fail2ban/jail.d/apache-jail.local <<'JAIL'
[apache-auth]
enabled = true
port = http,https
filter = apache-auth
logpath = /var/log/apache2/*error.log
maxretry = 5
JAIL

systemctl restart fail2ban || true
"

#### -------------------------
#### Optional: Zabbix agent
#### -------------------------
if [[ -n "$ZABBIX_SERVER" ]]; then
  echo "=> Instalando Zabbix agent apontando para $ZABBIX_SERVER..."
  _exec "apt install -y zabbix-agent || true
  sed -i 's/^Server=.*/Server=$ZABBIX_SERVER/' /etc/zabbix/zabbix_agentd.conf || true
  sed -i 's/^ServerActive=.*/ServerActive=$ZABBIX_SERVER/' /etc/zabbix/zabbix_agentd.conf || true
  systemctl enable zabbix-agent || true
  systemctl restart zabbix-agent || true
  "
fi

#### -------------------------
#### Finalização
#### -------------------------
echo "==========================================================="
echo "GLPI 11 (LXC NÃO-PRIVILEGIADO) instalado (CTID=$CTID)"
echo "Acesse: http://$IP_ADDR  (ou usar o IP/hostname configurado na sua rede)"
echo "DB: $DB_NAME  user: $DB_USER  (senha: $DB_PASS)"
echo "Pasta files montada do host: $HOST_GLPI_FILES_DIR  (UID host: $HOST_UID_WWW)"
echo "Backups: $BACKUP_DIR  (retenção: $RETENTION_KEEP backups)"
echo "Comandos úteis dentro do host Proxmox:"
echo " - pct console $CTID   # abrir console do container"
echo " - pct exec $CTID -- /bin/bash -c 'tail -f /var/log/apache2/glpi-error.log' # logs"
echo "Para atualizar o GLPI: /usr/local/bin/glpi-update.sh <versão>"
echo "Para rodar backup manual: /usr/local/bin/glpi-backup.sh"
echo "==========================================================="

exit 0
