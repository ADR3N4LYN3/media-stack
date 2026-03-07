#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Media Stack Freebox — Script d'installation v3
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

if [ -f "$PROJECT_DIR/.env" ]; then
    source <(grep -E '^(PUID|PGID|DATA_PATH|MEDIA_PATH)=' "$PROJECT_DIR/.env")
fi

DATA_PATH="${DATA_PATH:-/data}"
MEDIA_PATH="${MEDIA_PATH:-$DATA_PATH/media}"

mkdir -p "$DATA_PATH/downloads/complete" "$DATA_PATH/downloads/incomplete" "$MEDIA_PATH"
chown -R "${PUID}:${PGID}" "$DATA_PATH"

ok "Répertoires créés dans $DATA_PATH avec permissions ${PUID}:${PGID}"

# ── 3. Copie .env.example → .env ──

if [ ! -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    warn "Fichier .env créé depuis .env.example — À REMPLIR !"
else
    ok "Fichier .env déjà présent"
fi

# ── 4. Vérification des variables CHANGE_ME ──

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

# ── 5. Vérification /dev/net/tun (requis pour Gluetun) ──

info "Vérification de /dev/net/tun..."
if [ -c /dev/net/tun ]; then
    ok "/dev/net/tun disponible"
else
    die "/dev/net/tun non disponible — Gluetun ne pourra pas démarrer"
fi

# ── 6. Lancement ──

echo ""
read -rp "Lancer docker compose up -d ? [o/N] " confirm
if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
    info "Annulé. Lance manuellement : docker compose up -d"
    exit 0
fi

info "Démarrage des services..."
docker compose up -d

# ── 7. Attente healthcheck Gluetun ──

info "Attente du healthcheck Gluetun (timeout 120s)..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    status=$(docker inspect --format='{{.State.Health.Status}}' gluetun 2>/dev/null || echo "unknown")
    if [ "$status" = "healthy" ]; then
        ok "Gluetun est healthy (VPN connecté)"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -ne "\r  Attente de gluetun... ${ELAPSED}s / ${TIMEOUT}s"
done
if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    warn "Gluetun n'est pas healthy après ${TIMEOUT}s — vérifie les logs : docker logs gluetun"
fi

# ── 8. Résumé ──

echo ""
echo "═══════════════════════════════════════════"
echo "  Services démarrés !"
echo "═══════════════════════════════════════════"
echo ""
echo -e "  ${GREEN}Gluetun${NC}      → VPN Mullvad (tunnel WireGuard)"
echo -e "  ${GREEN}qBittorrent${NC}  → WebUI sur ${FREEBOX_WG_IP:-localhost}:8080"
echo -e "  ${GREEN}Jellyfin${NC}     → http://localhost:8096"
echo ""
echo "  Vérifier l'IP VPN : docker exec gluetun wget -qO- https://ipinfo.io/json"
echo ""
