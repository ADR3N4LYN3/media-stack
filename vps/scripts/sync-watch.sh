#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Media Stack — Sync Watch v2 (inotify + rclone)
# ═══════════════════════════════════════════
# Surveille /data/media et sync vers la Freebox en temps réel
# Fallback : sync complète toutes les heures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/rclone-sync.log"
RCLONE_CONF="$PROJECT_DIR/config/rclone/rclone.conf"

# Charger les variables d'environnement
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

MEDIA_PATH="${MEDIA_PATH:-/data/media}"
FREEBOX_MEDIA_PATH="${FREEBOX_MEDIA_PATH:-/mnt/NVMe/media}"
WEBHOOK_URL="${WEBHOOK_URL:-}"
RCLONE_FLAGS="--config=$RCLONE_CONF --transfers=4 --checkers=8 --multi-thread-streams=4 --buffer-size=64M --use-mmap --log-level=INFO --exclude *.part --exclude *.!qB"

# ── Fonctions utilitaires ──

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

send_webhook() {
    if [ -n "$WEBHOOK_URL" ]; then
        local message="$1"
        curl -s -H "Content-Type: application/json" \
            -d "{\"content\": \"$message\"}" \
            "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

human_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}") GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB"
    else
        echo "${bytes} B"
    fi
}

# Sync un fichier individuel avec retry et backoff exponentiel
sync_file() {
    local filepath="$1"
    local relative_path="${filepath#$MEDIA_PATH/}"
    local remote_dir
    remote_dir="$(dirname "$relative_path")"
    local backoff_delays=(10 30 90)
    local attempt=0
    local filesize
    filesize=$(stat -c%s "$filepath" 2>/dev/null || echo "0")
    local size_human
    size_human=$(human_size "$filesize")

    for delay in "${backoff_delays[@]}"; do
        attempt=$((attempt + 1))
        log "Sync fichier (tentative $attempt/3) : $relative_path ($size_human)"

        if rclone copy "$filepath" "freebox:${FREEBOX_MEDIA_PATH}/${remote_dir}" $RCLONE_FLAGS 2>>"$LOG_FILE"; then
            log "Sync OK : $relative_path ($size_human)"
            send_webhook "Sync OK : $relative_path ($size_human)"
            return 0
        fi

        log "Echec tentative $attempt. Retry dans ${delay}s..."
        sleep "$delay"
    done

    log "ECHEC DEFINITIF après 3 tentatives : $relative_path"
    send_webhook "Sync FAILED : $relative_path après 3 tentatives"
    return 1
}

# Sync complète
full_sync() {
    log "Démarrage sync complète..."
    if rclone sync "$MEDIA_PATH" "freebox:${FREEBOX_MEDIA_PATH}" $RCLONE_FLAGS 2>>"$LOG_FILE"; then
        log "Sync complète terminée avec succès"
        send_webhook "Sync complète terminée"
    else
        log "ERREUR lors de la sync complète"
        send_webhook "Erreur sync complète"
    fi
}

# ── Vérification prérequis ──

if ! command -v inotifywait &>/dev/null; then
    echo "ERREUR: inotifywait non trouvé. Installe inotify-tools."
    exit 1
fi

if ! command -v rclone &>/dev/null; then
    echo "ERREUR: rclone non trouvé."
    exit 1
fi

if [ ! -f "$RCLONE_CONF" ]; then
    echo "ERREUR: $RCLONE_CONF introuvable. Lance setup.sh d'abord."
    exit 1
fi

# Créer le fichier de log
touch "$LOG_FILE"

log "=== Démarrage sync-watch v2 ==="
log "Surveillance de : $MEDIA_PATH"
log "Destination : freebox:${FREEBOX_MEDIA_PATH}"

# ── Boucle principale ──

# Sync complète en arrière-plan toutes les heures
(
    while true; do
        sleep 3600
        full_sync
    done
) &
FULL_SYNC_PID=$!

# Cleanup à la sortie
cleanup() {
    log "Arrêt de sync-watch..."
    kill "$FULL_SYNC_PID" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Sync complète au démarrage
full_sync

# Surveillance inotify en temps réel
inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$MEDIA_PATH" | while read -r filepath; do
    # Ignorer les fichiers temporaires et partiels
    case "$filepath" in
        *.part|*.tmp|*.!qB|*~) continue ;;
    esac

    # Attendre 30 secondes de stabilité (vérifier que la taille ne change plus)
    log "Nouveau fichier détecté : $filepath — attente stabilisation (30s)..."
    sleep 15
    size1=$(stat -c%s "$filepath" 2>/dev/null || echo "0")
    sleep 15
    size2=$(stat -c%s "$filepath" 2>/dev/null || echo "0")

    if [ "$size1" != "$size2" ]; then
        log "Fichier encore en cours d'écriture : $filepath — skip (sera repris par la sync horaire)"
        continue
    fi

    # Vérifier que le fichier existe toujours
    if [ -f "$filepath" ]; then
        sync_file "$filepath" &
    else
        log "Fichier disparu avant sync : $filepath"
    fi
done
