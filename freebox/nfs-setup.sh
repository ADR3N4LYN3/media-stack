#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Media Stack Freebox — Installation NFS Server
# ═══════════════════════════════════════════
# Exporte /data vers le VPS via le tunnel WireGuard
# Usage : bash nfs-setup.sh <VPS_WG_IP>
# Exemple : bash nfs-setup.sh 192.168.27.65

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

# ── Verification des arguments ──

VPS_WG_IP="${1:-}"

if [ -z "$VPS_WG_IP" ]; then
    die "Usage : bash nfs-setup.sh <VPS_WG_IP>\n  Exemple : bash nfs-setup.sh 192.168.27.65\n  L'IP WireGuard du VPS se trouve dans le .env du VPS (WG_FREEBOX_ADDRESS sans le /32)"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Media Stack Freebox — NFS Server"
echo "═══════════════════════════════════════════"
echo ""

# Charger PUID/PGID depuis .env si disponible
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
DATA_PATH="${DATA_PATH:-/data}"

if [ -f "$SCRIPT_DIR/.env" ]; then
    source <(grep -E '^(PUID|PGID|DATA_PATH)=' "$SCRIPT_DIR/.env")
fi

# ── 1. Installation nfs-kernel-server ──

info "Installation de nfs-kernel-server..."

if ! dpkg -l | grep -q nfs-kernel-server; then
    apt-get update -qq && apt-get install -y -qq nfs-kernel-server
    ok "nfs-kernel-server installe"
else
    ok "nfs-kernel-server deja installe"
fi

# ── 2. Creation des repertoires ──

info "Verification des repertoires..."

mkdir -p "${DATA_PATH}/downloads/complete"
mkdir -p "${DATA_PATH}/downloads/incomplete"
mkdir -p "${DATA_PATH}/media/films"
mkdir -p "${DATA_PATH}/media/series"
chown -R "${PUID}:${PGID}" "${DATA_PATH}"
ok "Repertoires ${DATA_PATH} prets"

# ── 3. Configuration des exports NFS ──

info "Configuration des exports NFS..."

EXPORT_LINE="${DATA_PATH} ${VPS_WG_IP}(rw,sync,no_subtree_check,all_squash,anonuid=${PUID},anongid=${PGID})"

if grep -q "${DATA_PATH}.*${VPS_WG_IP}" /etc/exports 2>/dev/null; then
    ok "Export NFS deja configure"
else
    # Ajouter l'export
    echo "" >> /etc/exports
    echo "# Media Stack — export vers le VPS via WireGuard" >> /etc/exports
    echo "${EXPORT_LINE}" >> /etc/exports
    ok "Export NFS ajoute dans /etc/exports"
fi

echo ""
info "Export configure :"
echo "  ${EXPORT_LINE}"
echo ""

# ── 4. Application et demarrage ──

info "Application des exports..."
exportfs -ra
ok "Exports NFS appliques"

systemctl enable --now nfs-kernel-server
ok "nfs-kernel-server actif et active au demarrage"

# ── 5. Verification ──

echo ""
echo "═══════════════════════════════════════════"
echo "  NFS Server configure"
echo "═══════════════════════════════════════════"
echo ""
echo "  Export : ${DATA_PATH} -> ${VPS_WG_IP}"
echo ""
echo "  Pour verifier depuis le VPS :"
echo "    mount -t nfs4 ${FREEBOX_WG_IP:-<FREEBOX_WG_IP>}:${DATA_PATH} /mnt/freebox"
echo "    ls /mnt/freebox/media/films"
echo ""
