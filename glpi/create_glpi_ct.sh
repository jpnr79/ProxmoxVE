#!/usr/bin/env bash

echo "---- Criar CT Ubuntu no Proxmox ----"

# ================================
# Entrada de dados do usuário
# ================================
read -p "Informe o CT_ID (ex: 200): " CT_ID
read -p "Informe o IP (ex: 192.168.1.50/24 ou dhcp): " IP_ADDR
read -p "Informe o Gateway (ex: 192.168.1.1): " GATEWAY

# ================================
# Variáveis fixas
# ================================
HOSTNAME="ubuntu-${CT_ID}"
PASSWORD="SenhaForte123"
MEMORY="2048"
CORES="2"
DISK_SIZE="8"
BRIDGE="vmbr0"

# Timezone e Locale padrão (Portugal)
TIMEZONE="Europe/Lisbon"
LOCALE="pt_PT.UTF-8"

TEMPLATE="ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"

STORAGE="local-lvm"

# ================================
# Verificação de template
# ================================
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "❌ Template não encontrado em: $TEMPLATE_PATH"
    exit 1
fi

# ================================
# Criação do CT
# ================================
echo "📦 A criar CT Ubuntu ID: $CT_ID"

pct create $CT_ID "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME" \
    --password "$PASSWORD" \
    --cores $CORES \
    --memory $MEMORY \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_ADDR},gw=${GATEWAY}" \
    --unprivileged 1 \
    --features nesting=1 \
    --swap 512

if [ $? -ne 0 ]; then
    echo "❌ Erro na criação do container."
    exit 1
fi

echo "🚀 A iniciar CT..."
pct start $CT_ID
sleep 5

# ================================
# Configurar timezone (Portugal)
# ================================
echo "🕒 A definir timezone (${TIMEZONE})..."
pct exec $CT_ID -- bash -c "timedatectl set-timezone '${TIMEZONE}'"

# ================================
# Configurar locale (Portugal)
# ================================
echo "🌐 A configurar locale (${LOCALE})..."

pct exec $CT_ID -- bash -c "apt update && apt install -y locales"
pct exec $CT_ID -- bash -c "sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen"
pct exec $CT_ID -- bash -c "locale-gen '${LOCALE}'"
pct exec $CT_ID -- bash -c "update-locale LANG='${LOCALE}'"

# ================================
# Updates automáticos
# ================================
echo "🔧 A instalar updates dentro do CT..."
pct exec $CT_ID -- bash -c "apt update && apt full-upgrade -y && apt autoremove -y && apt clean"

echo "✅ CT criado, configurado com PT, timezone definido e atualizado!"
pct status $CT_ID
