#!/bin/bash
# =============================================
# UPDATE AUTOMÁTICO DO GLPI NO PROXMOX (SAFE/DEBUG)
# =============================================
set -euo pipefail
set -x  # Mostra cada comando antes de executar

# ================= CONFIGURAÇÕES =================
CT_ID="999"
GLPI_DIR="/var/www/glpi"
WWW_USER="www-data"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="YourStrongPassword"
GLPI_VERSION=""  # "" = última versão do GitHub
LOG_FILE="/var/log/glpi_update_safe.log"

# Cria log
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "====================================================="
echo "[INFO] Início do update GLPI em $(date)"
echo "Container: $CT_ID"
# ================= 1️⃣ Verificar container =================
if ! pct status "$CT_ID" | grep -q "running"; then
    echo "[WARN] Container $CT_ID não está ativo. Iniciando..."
    pct start "$CT_ID"
    sleep 5
fi
pct exec "$CT_ID" -- bash -c "echo '[INFO] Container está ativo'"

# ================= 2️⃣ Testar internet =================
echo "[INFO] Testando conectividade..."
until pct exec "$CT_ID" -- bash -c "ping -c1 8.8.8.8 &>/dev/null"; do
    echo "[WARN] Sem internet no container, aguardando 5s..."
    sleep 5
done
echo "[INFO] Internet OK"

# ================= 3️⃣ Determinar versão GLPI =================
if [[ -z "$GLPI_VERSION" ]]; then
    GLPI_VERSION=$(pct exec "$CT_ID" -- bash -c "wget -qO- https://api.github.com/repos/glpi-project/glpi/releases/latest | jq >
    echo "[INFO] Última versão detectada: $GLPI_VERSION"
else
    echo "[INFO] Usando versão específica: $GLPI_VERSION"
fi
# ================= 4️⃣ Backup das pastas críticas =================
BACKUP_DIR="/root/glpi_backup_safe_$(date +%F-%H%M)"
echo "[INFO] Criando backup em $BACKUP_DIR"
pct exec "$CT_ID" -- bash -c "mkdir -p $BACKUP_DIR"

for dir in config files marketplace plugins; do
    pct exec "$CT_ID" -- bash -c "if [ -d $GLPI_DIR/$dir ]; then cp -r $GLPI_DIR/$dir $BACKUP_DIR/; echo '[INFO] Backup $dir OK>
done

# ================= 5️⃣ Backup do banco =================
echo "[INFO] Backup do banco de dados..."
pct exec "$CT_ID" -- bash -c "mysqldump -u$DB_USER -p$DB_PASS $DB_NAME > $BACKUP_DIR/glpi_db_$(date +%F).sql && echo '[INFO] Ba>

# ================= 6️⃣ Download e extrair GLPI =================
echo "[INFO] Baixando GLPI $GLPI_VERSION..."
pct exec "$CT_ID" -- bash -c "
cd /tmp &&
rm -rf glpi_update glpi-$GLPI_VERSION.tgz &&
wget --tries=5 --timeout=30 -O glpi-$GLPI_VERSION.tgz https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi>
if [ ! -s glpi-$GLPI_VERSION.tgz ]; then
    echo '[ERRO] Arquivo GLPI vazio ou corrompido'; exit 1;
fi &&
mkdir glpi_update &&
tar -xvzf glpi-$GLPI_VERSION.tgz -C glpi_update &&
rm glpi-$GLPI_VERSION.tgz &&
echo '[INFO] GLPI $GLPI_VERSION baixado e extraído com sucesso'
"
# ================= 7️⃣ Atualizar GLPI mantendo pastas críticas =================
echo "[INFO] Atualizando GLPI..."
pct exec "$CT_ID" -- bash -c "
rm -rf $GLPI_DIR/*
cp -r /tmp/glpi_update/glpi/* $GLPI_DIR/
for dir in config files marketplace plugins; do
    if [ -d $BACKUP_DIR/\$dir ]; then
        cp -r $BACKUP_DIR/\$dir $GLPI_DIR/
        echo '[INFO] Restauração $dir OK'
    fi
done
rm -rf /tmp/glpi_update
"

# ================= 8️⃣ Ajustar permissões =================
echo "[INFO] Corrigindo permissões..."
pct exec "$CT_ID" -- bash -c "
chown -R $WWW_USER:$WWW_USER $GLPI_DIR
find $GLPI_DIR -type d -exec chmod 755 {} \;
find $GLPI_DIR -type f -exec chmod 644 {} \;
echo '[INFO] Permissões corrigidas'
"

# ================= 9️⃣ Cron automático =================
CRON_JOB="0 3 * * * /root/update_glpi_safe_pct.sh >> /var/log/glpi_update_safe.log 2>&1"
(crontab -l 2>/dev/null | grep -F -q "$CRON_JOB") || (
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "[INFO] Cron job adicionado para rodar diariamente às 03:00"
)
# ================= 10️⃣ Finalização =================
echo "[OK] GLPI atualizado com sucesso!"
echo "Versão instalada: $GLPI_VERSION"
echo "Backup salvo em: $BACKUP_DIR"
echo "Fim do update em $(date)"
echo "====================================================="
