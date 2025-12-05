Como usar
Ajuste as variáveis no topo do script (CTID, IP, RAM, etc.)

Execute no Proxmox host: chmod +x create_glpi_ct.sh && ./create_glpi_ct.sh

Aguarde ~10min - CT criado, GLPI instalado, backup cron configurado

Acesse http://IP_DO_CT e finalize wizard GLPI

Recursos incluídos
✅ CT Debian 12 otimizado (4GB RAM, 40GB disco)

✅ GLPI 11.0.4

✅ MariaDB tunado para GLPI (InnoDB 1G buffer)

✅ PHP 8.4 FPM + todas extensões GLPI

✅ Redis cache otimizado

✅ Backup diário arquivos+DB (retenção 7 dias)
    glpi_core_*.tar.gz (exclui plugins/marketplace)
    glpi_plugins_*.tar.gz (só plugins/marketplace)
    glpi_db_*.sql

✅ Update automático GLPI semanal
    rsync --exclude=plugins --exclude=marketplace
    Preserva 100% plugins instalados
    Preserva config do GLPI

✅ Apache VirtualHost otimizado

✅ Scripts /root/scripts/backup_glpi.sh e update_glpi.sh

✅ Cron jobs configurados

✅ Proxmox startup order (inicia primeiro)

✅ Bind mounts automáticos:
    /var/lib/vz/glpi-plugins-101 → /var/www/glpi/plugins
    /var/lib/vz/glpi-marketplace-101 → /var/www/glpi/marketplace

✅ Inicialização automática dos diretórios persistentes com www-data

🎯 Vantagens
Nunca perde plugins em updates

Marketplace sempre salvo

Backups menores (core separado)

Recuperação fácil (cada parte tem backup próprio)

Proxmox nativo (bind mounts visíveis na GUI)

Execute e terá GLPI 11 production-ready com plugins persistentes forever! 🛡️
