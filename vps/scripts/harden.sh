#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Media Stack VPS — Durcissement système
# ═══════════════════════════════════════════
# À exécuter une seule fois sur le VPS (idempotent)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Charger .env
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

SSH_PORT="${SSH_PORT:-2222}"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo "═══════════════════════════════════════════"
echo "  Durcissement système VPS"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. SSH Hardening ──

info "Configuration SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# Backup
if [ ! -f "${SSHD_CONFIG}.bak" ]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
    ok "Backup sshd_config créé"
fi

# Désactiver auth par mot de passe
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"

# Désactiver login root
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"

# Changer le port SSH
sed -i "s/^#\?Port.*/Port ${SSH_PORT}/" "$SSHD_CONFIG"

# Recharger sshd
systemctl reload sshd || systemctl reload ssh
ok "SSH configuré — port ${SSH_PORT}, password auth désactivé, root login désactivé"

echo ""
echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${RED}║  ATTENTION : NE FERME PAS cette session SSH !           ║${NC}"
echo -e "  ${RED}║  Ouvre un NOUVEAU terminal et teste :                   ║${NC}"
echo -e "  ${RED}║  ssh -p ${SSH_PORT} user@IP-DU-VPS                          ║${NC}"
echo -e "  ${RED}║  Si ça fonctionne, tu peux fermer cette session.        ║${NC}"
echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 2. Rappel Firewall Hetzner ──

echo -e "  ${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "  ${YELLOW}  Configure ces règles dans Hetzner Cloud Firewall    ${NC}"
echo -e "  ${YELLOW}  https://console.hetzner.cloud                       ${NC}"
echo -e "  ${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  INBOUND :"
echo "  TCP  ${SSH_PORT}        0.0.0.0/0, ::/0   (SSH)"
echo "  TCP  80           0.0.0.0/0, ::/0   (HTTP -> redirect HTTPS)"
echo "  TCP  443          0.0.0.0/0, ::/0   (HTTPS)"
echo "  UDP  443          0.0.0.0/0, ::/0   (HTTP/3 QUIC)"
echo ""
echo "  OUTBOUND : tout autoriser (défaut Hetzner)"
echo ""
echo "  Tout le reste est bloqué par défaut — aucun port interne"
echo "  (Sonarr, Radarr, Prowlarr, Homarr...) ne doit être accessible."
echo ""

# ── 3. Kernel tweaks ──

info "Application des tweaks kernel..."

SYSCTL_FILE="/etc/sysctl.d/99-hardening.conf"

cat > "$SYSCTL_FILE" << 'EOF'
# Media Stack — Hardening kernel
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.disable_ipv6 = 0
kernel.dmesg_restrict = 1
EOF

sysctl --system > /dev/null 2>&1
ok "Tweaks kernel appliqués"

# ── 4. Mises à jour de sécurité automatiques ──

info "Configuration des mises à jour de sécurité automatiques..."

if ! dpkg -l | grep -q unattended-upgrades; then
    apt-get update -qq && apt-get install -y -qq unattended-upgrades
fi

# Activer uniquement les mises à jour de sécurité
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

ok "Mises à jour de sécurité automatiques activées"

# ── 5. Docker daemon hardening ──

info "Configuration du daemon Docker..."

DOCKER_DAEMON="/etc/docker/daemon.json"

# Ne pas écraser si déjà configuré avec des settings custom
if [ ! -f "$DOCKER_DAEMON" ] || [ "$(cat "$DOCKER_DAEMON" 2>/dev/null)" = "{}" ]; then
    cat > "$DOCKER_DAEMON" << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "userland-proxy": false,
  "no-new-privileges": true,
  "live-restore": true
}
EOF
    systemctl restart docker
    ok "Docker daemon configuré et redémarré"
else
    warn "daemon.json déjà configuré — vérification manuelle recommandée"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Durcissement terminé !"
echo "═══════════════════════════════════════════"
echo ""
