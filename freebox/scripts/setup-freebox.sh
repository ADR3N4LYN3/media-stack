#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Media Stack Freebox — Script d'installation v2
# ═══════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

echo ""
echo "═══════════════════════════════════════════"
echo "  Media Stack Freebox — Installation"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. Vérification Docker ──

info "Vérification de Docker..."

if ! command -v docker &>/dev/null; then
    die "Docker n'est pas disponible. Vérifie que Docker est activé dans Freebox OS."
fi
ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

if ! docker compose version &>/dev/null; then
    die "Docker Compose v2 non disponible."
fi
ok "Docker Compose $(docker compose version --short)"

# ── 2. Création des répertoires ──

info "Création des répertoires..."

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Lire MEDIA_PATH depuis .env si disponible
if [ -f "$PROJECT_DIR/.env" ]; then
    MEDIA_PATH="$(grep -E '^MEDIA_PATH=' "$PROJECT_DIR/.env" | cut -d'=' -f2- | xargs)"
fi
MEDIA_PATH="${MEDIA_PATH:-/mnt/NVMe/media}"

mkdir -p "$MEDIA_PATH"

chown -R "${PUID}:${PGID}" "$MEDIA_PATH"

ok "Répertoire $MEDIA_PATH créé avec permissions ${PUID}:${PGID}"

# ── 3. Configuration SFTP (conteneur openssh-server) ──

info "Configuration du conteneur SFTP..."

mkdir -p "$PROJECT_DIR/config/sftp/ssh"

ok "Répertoire config SFTP créé"

# ── 4. Copie .env.example → .env ──

if [ ! -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    warn "Fichier .env créé depuis .env.example — À REMPLIR !"
else
    ok "Fichier .env déjà présent"
fi

# ── 5. Vérification des variables CHANGE_ME ──

info "Vérification des variables..."

MISSING=()
while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    if [ "$value" = "CHANGE_ME" ]; then
        MISSING+=("$key")
    fi
done < "$PROJECT_DIR/.env"

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}[ERREUR]${NC} Variables non configurées dans .env :"
    echo ""
    for var in "${MISSING[@]}"; do
        echo -e "  ${YELLOW}→ $var${NC}"
    done
    echo ""
    echo "Remplis ces variables dans $PROJECT_DIR/.env puis relance ce script."
    exit 1
fi

ok "Toutes les variables sont configurées"

source "$PROJECT_DIR/.env"

# ── 6. Ajout clé SSH publique du VPS (pour SFTP) ──

AUTHORIZED_KEY="$PROJECT_DIR/config/sftp/ssh/authorized_key"

echo ""
echo "═══════════════════════════════════════════"
echo "  Clé SSH du VPS (pour SFTP via WireGuard)"
echo "═══════════════════════════════════════════"
echo ""
echo "Colle la clé publique SSH du VPS (affichée par setup.sh côté VPS) :"
echo "(Laisse vide et appuie sur Entrée pour passer)"
echo ""
read -rp "Clé publique : " ssh_pubkey

if [ -n "$ssh_pubkey" ]; then
    if [ ! -f "$AUTHORIZED_KEY" ] || ! grep -qF "$ssh_pubkey" "$AUTHORIZED_KEY" 2>/dev/null; then
        echo "$ssh_pubkey" > "$AUTHORIZED_KEY"
        chmod 644 "$AUTHORIZED_KEY"
        ok "Clé SSH ajoutée pour le conteneur SFTP"
    else
        ok "Clé SSH déjà présente"
    fi
else
    warn "Clé SSH ignorée. Ajoute-la manuellement dans config/sftp/ssh/authorized_key"
fi

# ── 7. Lancement ──

echo ""
read -rp "Lancer docker compose up -d ? [o/N] " confirm
if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
    info "Annulé. Lance manuellement : docker compose up -d"
    exit 0
fi

info "Démarrage du conteneur SFTP..."
docker compose up -d

# ── 8. Résumé ──

echo ""
echo "═══════════════════════════════════════════"
echo "  SFTP démarré !"
echo "═══════════════════════════════════════════"
echo ""
echo -e "  ${GREEN}SFTP${NC}  → port 2222 (via tunnel WireGuard)"
echo ""
echo "  Les médias synchronisés par rclone seront disponibles"
echo "  directement via le player Freebox sur le NVMe interne."
echo ""
