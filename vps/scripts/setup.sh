#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Media Stack VPS — Script d'installation v2
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
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }
die()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

# Cleanup en cas d'erreur
cleanup() {
    if [ $? -ne 0 ]; then
        echo ""
        fail "Le script a échoué. Corrige l'erreur ci-dessus et relance."
    fi
}
trap cleanup EXIT

echo ""
echo "═══════════════════════════════════════════"
echo "  Media Stack VPS — Installation"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. Vérification / Installation des prérequis ──

info "Vérification des prérequis..."

# Docker
if ! command -v docker &>/dev/null; then
    warn "Docker non trouvé. Installation en cours..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installé"
else
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
fi

# Docker Compose v2
if ! docker compose version &>/dev/null; then
    die "Docker Compose v2 non disponible. Mets à jour Docker."
fi
ok "Docker Compose $(docker compose version --short)"

# inotifywait (pour sync-watch.sh)
if ! command -v inotifywait &>/dev/null; then
    warn "inotifywait non trouvé. Installation..."
    apt-get update -qq && apt-get install -y -qq inotify-tools
    ok "inotify-tools installé"
else
    ok "inotifywait disponible"
fi

# ── 2. Création de la structure de répertoires ──

info "Création des répertoires..."

mkdir -p /data/downloads/complete
mkdir -p /data/downloads/incomplete
mkdir -p /data/media/films
mkdir -p /data/media/series
mkdir -p /var/log/caddy
mkdir -p "$PROJECT_DIR/config/homarr/configs"
mkdir -p "$PROJECT_DIR/config/homarr/icons"
mkdir -p "$PROJECT_DIR/config/homarr/data"

# Charger PUID/PGID depuis .env si disponible, sinon défaut 1000
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ -f "$PROJECT_DIR/.env" ]; then
    source <(grep -E '^(PUID|PGID)=' "$PROJECT_DIR/.env")
fi

chown -R "${PUID}:${PGID}" /data
ok "Répertoires créés avec permissions ${PUID}:${PGID}"

# ── 3. Génération de la clé SSH pour rclone ──

SSH_KEY="$PROJECT_DIR/config/rclone/id_rsa"

if [ ! -f "$SSH_KEY" ]; then
    info "Génération de la clé SSH dédiée pour rclone..."
    mkdir -p "$PROJECT_DIR/config/rclone"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "media-stack-rclone"
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"
    ok "Clé SSH Ed25519 générée"
else
    ok "Clé SSH déjà existante"
fi

# ── 4. Copie .env.example → .env ──

if [ ! -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    warn "Fichier .env créé depuis .env.example — À REMPLIR avant de continuer !"
else
    ok "Fichier .env déjà présent"
fi

# ── 5. Charger .env et vérifier les variables CHANGE_ME ──

info "Vérification des variables d'environnement..."

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
    fail "Variables non configurées dans .env :"
    echo ""
    printf "  ${CYAN}%-30s${NC} %s\n" "VARIABLE" "STATUS"
    printf "  %-30s %s\n" "──────────────────────────────" "──────"
    for var in "${MISSING[@]}"; do
        printf "  ${YELLOW}%-30s${NC} ${RED}CHANGE_ME${NC}\n" "$var"
    done
    echo ""
    echo "Remplis ces variables dans $PROJECT_DIR/.env puis relance ce script."
    exit 1
fi

ok "Toutes les variables sont configurées"

# Charger les variables
source "$PROJECT_DIR/.env"

# ── 6. Génération rclone.conf depuis le template ──

info "Génération de rclone.conf..."

RCLONE_CONF="$PROJECT_DIR/config/rclone/rclone.conf"
RCLONE_TEMPLATE="$PROJECT_DIR/config/rclone/rclone.conf.template"

if [ -f "$RCLONE_TEMPLATE" ]; then
    sed \
        -e "s|FREEBOX_HOST_PLACEHOLDER|${FREEBOX_HOST}|g" \
        -e "s|FREEBOX_USER_PLACEHOLDER|${FREEBOX_USER}|g" \
        "$RCLONE_TEMPLATE" > "$RCLONE_CONF"
    ok "rclone.conf généré"
else
    die "Template rclone.conf.template introuvable"
fi

# ── 7. Scan de la clé hôte Freebox ──

KNOWN_HOSTS="$PROJECT_DIR/config/rclone/known_hosts"

if [ ! -f "$KNOWN_HOSTS" ] || ! grep -q "${FREEBOX_HOST}" "$KNOWN_HOSTS" 2>/dev/null; then
    info "Scan de la clé hôte de la Freebox (${FREEBOX_HOST})..."
    if ssh-keyscan -H "${FREEBOX_HOST}" >> "$KNOWN_HOSTS" 2>/dev/null; then
        ok "Clé hôte Freebox ajoutée à known_hosts"
    else
        warn "Impossible de scanner ${FREEBOX_HOST} — vérifie que SSH est actif sur la Freebox"
    fi
else
    ok "Clé hôte Freebox déjà dans known_hosts"
fi

# ── 8. Affichage de la clé publique SSH ──

echo ""
echo "═══════════════════════════════════════════"
echo "  Clé publique SSH à copier sur la Freebox"
echo "═══════════════════════════════════════════"
echo ""
echo -e "${CYAN}"
cat "${SSH_KEY}.pub"
echo -e "${NC}"
echo "→ Copie cette clé dans ~/.ssh/authorized_keys sur la Freebox"
echo ""

# ── 9. Durcissement système ──

if [ -f "$SCRIPT_DIR/harden.sh" ]; then
    read -rp "Lancer le durcissement système (harden.sh) ? [o/N] " harden_confirm
    if [[ "$harden_confirm" =~ ^[oOyY]$ ]]; then
        bash "$SCRIPT_DIR/harden.sh"
    else
        warn "Durcissement ignoré. Lance manuellement : bash scripts/harden.sh"
    fi
fi

# ── 10. Confirmation avant lancement ──

echo ""
read -rp "Lancer docker compose up -d ? [o/N] " confirm
if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
    info "Annulé. Lance manuellement : docker compose up -d"
    exit 0
fi

# ── 11. Lancement ──

info "Démarrage des services..."
docker compose up -d

# ── 12. Attente healthchecks ──

info "Attente des healthchecks (timeout 120s)..."

SERVICES_TO_CHECK=("gluetun" "prowlarr")
TIMEOUT=120
ELAPSED=0

for svc in "${SERVICES_TO_CHECK[@]}"; do
    while [ $ELAPSED -lt $TIMEOUT ]; do
        status=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
            ok "$svc est healthy"
            break
        fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        echo -ne "\r  Attente de $svc... ${ELAPSED}s / ${TIMEOUT}s"
    done
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        warn "$svc n'est pas healthy après ${TIMEOUT}s — vérifie les logs : docker logs $svc"
    fi
    ELAPSED=0
done

# ── 13. Résumé ──

DOMAIN="${DOMAIN:-localhost}"

echo ""
echo "═══════════════════════════════════════════"
echo "  Services démarrés !"
echo "═══════════════════════════════════════════"
echo ""
printf "  ${GREEN}%-15s${NC} %s\n" "Overseerr"   "https://overseerr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Homarr"      "https://home.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Sonarr"      "https://sonarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Radarr"      "https://radarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Prowlarr"    "https://prowlarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "qBittorrent" "https://qbittorrent.${DOMAIN}"
echo ""
echo "  Prochaine étape : Prowlarr → Sonarr/Radarr → Overseerr → Homarr"
echo ""
