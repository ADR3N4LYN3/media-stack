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

# WireGuard (tunnel vers Freebox)
if ! command -v wg &>/dev/null; then
    warn "WireGuard non trouvé. Installation..."
    apt-get update -qq && apt-get install -y -qq wireguard
    ok "WireGuard installé"
else
    ok "WireGuard $(wg --version 2>/dev/null || echo 'disponible')"
fi

# ── 2. Création de la structure de répertoires ──

info "Création des répertoires..."

# Charger PUID/PGID depuis .env si disponible, sinon défaut 1000
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ -f "$PROJECT_DIR/.env" ]; then
    source <(grep -E '^(PUID|PGID)=' "$PROJECT_DIR/.env")
fi

# Données media
mkdir -p /data/downloads/complete
mkdir -p /data/downloads/incomplete
mkdir -p /data/media/films
mkdir -p /data/media/series
chown -R "${PUID}:${PGID}" /data

# Configs des services (permissions correctes dès la création)
CONFIG_DIRS=(
    "gluetun"
    "qbittorrent"
    "prowlarr"
    "sonarr"
    "radarr"
    "overseerr"
    "homepage"
    "qbittorrent/custom-services.d"
)

for dir in "${CONFIG_DIRS[@]}"; do
    mkdir -p "$PROJECT_DIR/config/$dir"
done

chown -R "${PUID}:${PGID}" "$PROJECT_DIR/config"
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

# ── 6. Configuration du tunnel WireGuard vers la Freebox ──

WG_CONF="/etc/wireguard/wg-freebox.conf"

if [ ! -f "$WG_CONF" ]; then
    info "Génération de la config WireGuard (tunnel → Freebox)..."
    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${WG_FREEBOX_PRIVATE_KEY}
Address = ${WG_FREEBOX_ADDRESS}
MTU = 1360

[Peer]
PublicKey = ${WG_FREEBOX_PUBLIC_KEY}
Endpoint = ${WG_FREEBOX_ENDPOINT}:${WG_FREEBOX_PORT}
AllowedIPs = ${FREEBOX_WG_IP}/32
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_CONF"
    ok "Config WireGuard générée dans $WG_CONF"
else
    ok "Config WireGuard déjà existante"
fi

# Activation du tunnel
if ! wg show wg-freebox &>/dev/null; then
    info "Activation du tunnel WireGuard..."
    wg-quick up wg-freebox
    systemctl enable wg-quick@wg-freebox
    ok "Tunnel WireGuard actif et activé au démarrage"
else
    ok "Tunnel WireGuard déjà actif"
fi

# Test de connectivité
info "Test de connectivité vers la Freebox via le tunnel..."
if ping -c 1 -W 5 "${FREEBOX_WG_IP}" &>/dev/null; then
    ok "Freebox accessible via le tunnel WireGuard (${FREEBOX_WG_IP})"
else
    warn "Freebox non joignable via ${FREEBOX_WG_IP} — vérifie que le serveur WireGuard est actif sur la Freebox"
fi

# ── 7. Génération rclone.conf depuis le template ──

info "Génération de rclone.conf..."

RCLONE_CONF="$PROJECT_DIR/config/rclone/rclone.conf"
RCLONE_TEMPLATE="$PROJECT_DIR/config/rclone/rclone.conf.template"

if [ -f "$RCLONE_TEMPLATE" ]; then
    sed \
        -e "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
        -e "s|FREEBOX_SFTP_USER_PLACEHOLDER|${FREEBOX_SFTP_USER}|g" \
        -e "s|FREEBOX_SFTP_PORT_PLACEHOLDER|${FREEBOX_SFTP_PORT}|g" \
        "$RCLONE_TEMPLATE" > "$RCLONE_CONF"
    ok "rclone.conf généré"
else
    die "Template rclone.conf.template introuvable"
fi

# ── 8. Scan de la clé hôte SFTP Freebox (via tunnel) ──

KNOWN_HOSTS="$PROJECT_DIR/config/rclone/known_hosts"

info "Scan de la clé hôte SFTP Freebox (${FREEBOX_WG_IP}:${FREEBOX_SFTP_PORT})..."
if ssh-keyscan -p "${FREEBOX_SFTP_PORT}" -H "${FREEBOX_WG_IP}" >> "$KNOWN_HOSTS" 2>/dev/null; then
    ok "Clé hôte SFTP ajoutée à known_hosts"
else
    warn "Impossible de scanner — le conteneur SFTP n'est peut-être pas encore lancé sur la Freebox"
fi

# ── 9. Affichage de la clé publique SSH (pour le conteneur SFTP Freebox) ──

echo ""
echo "═══════════════════════════════════════════"
echo "  Clé publique SSH à copier sur la Freebox"
echo "═══════════════════════════════════════════"
echo ""
echo -e "${CYAN}"
cat "${SSH_KEY}.pub"
echo -e "${NC}"
echo "→ Colle cette clé dans le setup-freebox.sh (ou dans freebox/config/sftp/ssh/authorized_key)"
echo ""

# ── 10. Configuration nginx reverse proxy ──

info "Configuration nginx..."

# Vérifier que nginx est installé
if ! command -v nginx &>/dev/null; then
    warn "nginx non trouvé. Installation..."
    apt-get update -qq && apt-get install -y -qq nginx apache2-utils
    ok "nginx installé"
else
    ok "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}')"
fi

# Installer apache2-utils pour htpasswd si pas déjà présent
if ! command -v htpasswd &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq apache2-utils
fi

# Vérifier les certificats Cloudflare
if [ ! -f /etc/ssl/cloudflare/cert.pem ] || [ ! -f /etc/ssl/cloudflare/key.pem ]; then
    warn "Certificats Cloudflare non trouvés dans /etc/ssl/cloudflare/"
    echo "  Crée les certificats origin dans Cloudflare Dashboard → SSL/TLS → Origin Server"
    echo "  Puis place-les dans /etc/ssl/cloudflare/cert.pem et key.pem"
fi

# Générer le htpasswd
HTPASSWD_FILE="/etc/nginx/.htpasswd-media"
info "Génération du fichier htpasswd..."
htpasswd -bc "$HTPASSWD_FILE" "${NGINX_USER}" "${NGINX_PASSWORD}" 2>/dev/null
chmod 640 "$HTPASSWD_FILE"
chown root:www-data "$HTPASSWD_FILE"
ok "Fichier htpasswd généré pour l'utilisateur ${NGINX_USER}"

# Générer le htpasswd Homepage (creds séparés)
HTPASSWD_HOMEPAGE="/etc/nginx/.htpasswd-homepage"
htpasswd -bc "$HTPASSWD_HOMEPAGE" "${HOMEPAGE_USER}" "${HOMEPAGE_PASSWORD}" 2>/dev/null
chmod 640 "$HTPASSWD_HOMEPAGE"
chown root:www-data "$HTPASSWD_HOMEPAGE"
ok "Fichier htpasswd Homepage généré pour l'utilisateur ${HOMEPAGE_USER}"

# Générer la config nginx depuis le template
NGINX_TEMPLATE="$PROJECT_DIR/nginx/media-stack.conf.template"
NGINX_CONF="/etc/nginx/sites-available/media-stack"

if [ -f "$NGINX_TEMPLATE" ]; then
    sed "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "$NGINX_TEMPLATE" > "$NGINX_CONF"
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/media-stack
    ok "Config nginx générée pour *.${DOMAIN}"
else
    die "Template nginx introuvable : $NGINX_TEMPLATE"
fi

# Test et reload nginx
if nginx -t 2>/dev/null; then
    systemctl reload nginx
    ok "nginx rechargé"
else
    warn "Erreur dans la config nginx — vérifie avec : nginx -t"
fi

# ── 11. Durcissement système ──

if [ -f "$SCRIPT_DIR/harden.sh" ]; then
    read -rp "Lancer le durcissement système (harden.sh) ? [o/N] " harden_confirm
    if [[ "$harden_confirm" =~ ^[oOyY]$ ]]; then
        bash "$SCRIPT_DIR/harden.sh"
    else
        warn "Durcissement ignoré. Lance manuellement : bash scripts/harden.sh"
    fi
fi

# ── 12. Confirmation avant lancement ──

echo ""
read -rp "Lancer docker compose up -d ? [o/N] " confirm
if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
    info "Annulé. Lance manuellement : docker compose up -d"
    exit 0
fi

# ── 13. Lancement ──

info "Démarrage des services..."
docker compose up -d

# ── 14. Attente healthchecks ──

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

# ── 15. Résumé ──

DOMAIN="${DOMAIN:-localhost}"

echo ""
echo "═══════════════════════════════════════════"
echo "  Services démarrés !"
echo "═══════════════════════════════════════════"
echo ""
printf "  ${GREEN}%-15s${NC} %s\n" "Overseerr"   "https://overseerr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Homepage"    "https://home.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Sonarr"      "https://sonarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Radarr"      "https://radarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Prowlarr"    "https://prowlarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "qBittorrent" "https://qbittorrent.${DOMAIN}"
echo ""
echo "  Prochaine étape : Prowlarr → Sonarr/Radarr → Overseerr → Homepage"
echo ""
