install_glpi() {
    section "Instalando GLPI"

    pct exec "$CT_ID" -- bash -c "
GLPI_DIR=\"/var/www/html/glpi\"

# Garantir ferramentas
apt update
apt install -y wget jq

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

# A extração gera algo como glpi‑<hash> — renomear para glpi
EXTRACTED_DIR=\$(tar -tf /tmp/glpi-latest.tar.gz | head -1 | cut -f1 -d\"/\")
mv \"/var/www/html/\$EXTRACTED_DIR\" \"\$GLPI_DIR\" 2>/dev/null || true

# Permissões
chown -R www-data:www-data \$GLPI_DIR
chmod -R 755 \$GLPI_DIR

# Configurar VirtualHost Apache para GLPI
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

a2ensite glpi.conf
a2dissite 000-default.conf

service apache2 restart
service php8.4-fpm restart
" || abort "Falha ao instalar GLPI."

    log "GLPI instalado com sucesso."
}
