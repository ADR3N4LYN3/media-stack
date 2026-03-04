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

mkdir -p /mnt/NVMe/media/films
mkdir -p /mnt/NVMe/media/series
mkdir -p /opt/plex/config
mkdir -p /opt/plex/transcode

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

chown -R "${PUID}:${PGID}" /mnt/NVMe/media
chown -R "${PUID}:${PGID}" /opt/plex

ok "Répertoires créés avec permissions ${PUID}:${PGID}"

# ── 3. Configuration SSH ──

info "Configuration SSH..."

mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

ok "Répertoire SSH configuré (permissions 700/600)"

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

    # Warning spécial PLEX_CLAIM
    for var in "${MISSING[@]}"; do
        if [ "$var" = "PLEX_CLAIM" ]; then
            echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${RED}║  Récupère ton claim token MAINTENANT :                   ║${NC}"
            echo -e "  ${RED}║  https://plex.tv/claim                                   ║${NC}"
            echo -e "  ${RED}║  Il expire dans 4 minutes !                              ║${NC}"
            echo -e "  ${RED}║  Mets-le dans .env puis relance ce script.               ║${NC}"
            echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
            echo ""
            break
        fi
    done

    echo "Remplis ces variables dans $PROJECT_DIR/.env puis relance ce script."
    exit 1
fi

ok "Toutes les variables sont configurées"

source "$PROJECT_DIR/.env"

# ── 6. Ajout clé SSH publique du VPS ──

echo ""
echo "═══════════════════════════════════════════"
echo "  Clé SSH du VPS"
echo "═══════════════════════════════════════════"
echo ""
echo "Colle la clé publique SSH du VPS (affichée par setup.sh côté VPS) :"
echo "(Laisse vide et appuie sur Entrée pour passer)"
echo ""
read -rp "Clé publique : " ssh_pubkey

if [ -n "$ssh_pubkey" ]; then
    if ! grep -qF "$ssh_pubkey" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "$ssh_pubkey" >> ~/.ssh/authorized_keys
        ok "Clé SSH ajoutée à ~/.ssh/authorized_keys"
    else
        ok "Clé SSH déjà présente"
    fi
else
    warn "Clé SSH ignorée. Ajoute-la manuellement plus tard."
fi

# ── 7. Lancement ──

echo ""
read -rp "Lancer docker compose up -d ? [o/N] " confirm
if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
    info "Annulé. Lance manuellement : docker compose up -d"
    exit 0
fi

info "Démarrage de Plex..."
docker compose up -d

# ── 8. Attente que Plex soit accessible ──

info "Attente que Plex soit accessible..."

FREEBOX_IP="${FREEBOX_IP:-localhost}"
TIMEOUT=60
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    if curl -s -o /dev/null -w '%{http_code}' "http://${FREEBOX_IP}:32400/identity" | grep -q "200"; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -ne "\r  Attente de Plex... ${ELAPSED}s / ${TIMEOUT}s"
done

echo ""

if [ $ELAPSED -ge $TIMEOUT ]; then
    warn "Plex ne répond pas encore — il peut prendre plus de temps au premier démarrage"
else
    ok "Plex est accessible"
fi

# ── 9. Résumé ──

echo ""
echo "═══════════════════════════════════════════"
echo "  Plex Media Server démarré !"
echo "═══════════════════════════════════════════"
echo ""
echo -e "  ${GREEN}Plex${NC} → http://${FREEBOX_IP}:32400/web"
echo ""
echo "  Prochaines étapes :"
echo "  1. Ouvre Plex et termine la configuration initiale"
echo "  2. Ajoute les bibliothèques :"
echo "     - Films  → /data/films"
echo "     - Séries → /data/series"
echo ""
echo "  Réglages recommandés dans Plex :"
echo "  - Transcoder quality → \"Make my CPU hurt\""
echo "  - Background transcoding → veryfast"
echo "  - Generate video preview thumbnails → Désactivé"
echo "  - Generate chapter image thumbnails → Désactivé"
echo ""
