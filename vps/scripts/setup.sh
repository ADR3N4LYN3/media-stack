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

# NFS client (pour monter les médias Freebox)
if ! command -v mount.nfs4 &>/dev/null; then
    warn "nfs-common non trouvé. Installation..."
    apt-get update -qq && apt-get install -y -qq nfs-common
    ok "nfs-common installé"
else
    ok "nfs-common disponible"
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

# Charger PUID/PGID depuis .env si disponible
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ -f "$PROJECT_DIR/.env" ]; then
    source <(grep -E '^(PUID|PGID)=' "$PROJECT_DIR/.env")
fi

# Point de montage NFS Freebox (les données média sont sur la Freebox)
mkdir -p /mnt/freebox

# Configs des services (permissions correctes dès la création)
CONFIG_DIRS=(
    "prowlarr"
    "sonarr"
    "radarr"
    "overseerr"
    "homepage"
    "jackett"
    "byparr"
    "authelia"
)

for dir in "${CONFIG_DIRS[@]}"; do
    mkdir -p "$PROJECT_DIR/config/$dir"
done

chown -R "${PUID}:${PGID}" "$PROJECT_DIR/config"
ok "Répertoires créés avec permissions ${PUID}:${PGID}"

# ── 3. Copie .env.example → .env ──

if [ ! -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    warn "Fichier .env créé depuis .env.example — À REMPLIR avant de continuer !"
else
    ok "Fichier .env déjà présent"
fi

# ── 4. Charger .env et vérifier les variables CHANGE_ME ──

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

# ── 5. Configuration du tunnel WireGuard vers la Freebox ──

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

# ── 6. Montage NFS Freebox (médias via WireGuard) ──

info "Configuration du montage NFS Freebox..."

NFS_MOUNT_UNIT="/etc/systemd/system/mnt-freebox.mount"

if [ ! -f "$NFS_MOUNT_UNIT" ]; then
    sed "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
        "$PROJECT_DIR/systemd/mnt-freebox.mount" > "$NFS_MOUNT_UNIT"
    systemctl daemon-reload
    systemctl enable mnt-freebox.mount
    ok "Unit systemd mnt-freebox.mount installée"
else
    ok "Unit systemd mnt-freebox.mount déjà existante"
fi

# Tenter le montage
if ! mountpoint -q /mnt/freebox; then
    info "Montage NFS /mnt/freebox..."
    if systemctl start mnt-freebox.mount 2>/dev/null; then
        ok "NFS monté sur /mnt/freebox"
    else
        warn "Montage NFS échoué — vérifie que le NFS server est actif sur la Freebox (bash nfs-setup.sh)"
    fi
else
    ok "NFS déjà monté sur /mnt/freebox"
fi

# ── 7. Configuration Authelia SSO ──

info "Configuration Authelia..."

# Générer configuration.yml depuis le template
AUTHELIA_CONF="$PROJECT_DIR/config/authelia/configuration.yml"
AUTHELIA_CONF_TEMPLATE="$PROJECT_DIR/config/authelia/configuration.yml.template"

if [ -f "$AUTHELIA_CONF_TEMPLATE" ]; then
    sed "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "$AUTHELIA_CONF_TEMPLATE" > "$AUTHELIA_CONF"
    ok "configuration.yml généré pour ${DOMAIN}"
else
    die "Template Authelia introuvable : $AUTHELIA_CONF_TEMPLATE"
fi

# Générer le hash du mot de passe Authelia
AUTHELIA_USERS_DB="$PROJECT_DIR/config/authelia/users_database.yml"
AUTHELIA_USERS_TEMPLATE="$PROJECT_DIR/config/authelia/users_database.yml"

if grep -q "AUTHELIA_HASH_PLACEHOLDER" "$AUTHELIA_USERS_DB" 2>/dev/null; then
    info "Génération du hash Argon2id pour Authelia..."
    AUTHELIA_HASH=$(echo -n "${AUTHELIA_PASSWORD}" | docker run --rm -i --entrypoint authelia authelia/authelia:latest crypto hash generate argon2 --stdin 2>/dev/null | grep 'Digest:' | awk '{print $2}')
    if [ -z "$AUTHELIA_HASH" ]; then
        die "Impossible de générer le hash Authelia. Vérifie que Docker fonctionne."
    fi
    sed -i \
        -e "s|AUTHELIA_USER_PLACEHOLDER|${AUTHELIA_USER}|g" \
        -e "s|AUTHELIA_HASH_PLACEHOLDER|${AUTHELIA_HASH}|g" \
        -e "s|AUTHELIA_EMAIL_PLACEHOLDER|${AUTHELIA_EMAIL}|g" \
        "$AUTHELIA_USERS_DB"
    ok "Utilisateur Authelia '${AUTHELIA_USER}' configuré"
else
    ok "Utilisateurs Authelia déjà configurés"
fi

ok "Authelia configuré pour le domaine ${DOMAIN}"

# ── 8. Configuration nginx reverse proxy ──

info "Configuration nginx..."

# Vérifier que nginx est installé
if ! command -v nginx &>/dev/null; then
    warn "nginx non trouvé. Installation..."
    apt-get update -qq && apt-get install -y -qq nginx
    ok "nginx installé"
else
    ok "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}')"
fi

# Vérifier les certificats Cloudflare
if [ ! -f /etc/ssl/cloudflare/cert.pem ] || [ ! -f /etc/ssl/cloudflare/key.pem ]; then
    warn "Certificats Cloudflare non trouvés dans /etc/ssl/cloudflare/"
    echo "  Crée les certificats origin dans Cloudflare Dashboard → SSL/TLS → Origin Server"
    echo "  Puis place-les dans /etc/ssl/cloudflare/cert.pem et key.pem"
fi

# Installer les snippets nginx (SSL commun + Authelia)
SNIPPETS_DIR="/etc/nginx/snippets"
mkdir -p "$SNIPPETS_DIR"
cp "$PROJECT_DIR/nginx/snippets/ssl-common.conf" "$SNIPPETS_DIR/"
cp "$PROJECT_DIR/nginx/snippets/authelia-location.conf" "$SNIPPETS_DIR/"
sed "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "$PROJECT_DIR/nginx/snippets/authelia-authrequest.conf" > "$SNIPPETS_DIR/authelia-authrequest.conf"
ok "Snippets nginx installés dans $SNIPPETS_DIR"

# Générer la config nginx depuis le template
NGINX_TEMPLATE="$PROJECT_DIR/nginx/media-stack.conf.template"
NGINX_CONF="/etc/nginx/sites-available/media-stack"

if [ -f "$NGINX_TEMPLATE" ]; then
    sed -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
        -e "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
        "$NGINX_TEMPLATE" > "$NGINX_CONF"
    rm -f /etc/nginx/sites-enabled/default
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

SERVICES_TO_CHECK=("prowlarr" "authelia")
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
printf "  ${GREEN}%-15s${NC} %s\n" "Authelia"    "https://auth.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Seerr"       "https://seerr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Homepage"    "https://home.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Sonarr"      "https://sonarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Radarr"      "https://radarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "Prowlarr"    "https://prowlarr.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "qBittorrent" "https://qbittorrent.${DOMAIN} (via Freebox)"
printf "  ${GREEN}%-15s${NC} %s\n" "Jackett"     "https://jackett.${DOMAIN}"
printf "  ${GREEN}%-15s${NC} %s\n" "NFS Freebox" "/mnt/freebox (${FREEBOX_WG_IP}:/data)"
echo ""
echo "  DNS requis : auth, seerr, home, sonarr, radarr, prowlarr, qbittorrent, jackett, logs → A record vers IP VPS"
echo ""
echo "  Prochaine étape : Authelia (2FA) → Prowlarr → Sonarr/Radarr (download client: ${FREEBOX_WG_IP}:8080) → Seerr → Homepage"
echo ""
