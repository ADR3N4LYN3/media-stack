# Operations & Troubleshooting

Guide operationnel pour la maintenance, le monitoring et le depannage de la media stack.

---

## Table des matieres

1. [Commandes de reference](#1-commandes-de-reference)
2. [Monitoring](#2-monitoring)
3. [Maintenance](#3-maintenance)
4. [Troubleshooting](#4-troubleshooting)
5. [Sync avancee (sync-watch.sh)](#5-sync-avancee-sync-watchsh)
6. [Sauvegardes](#6-sauvegardes)
7. [Procedures d'urgence](#7-procedures-durgence)

---

## 1. Commandes de reference

### Docker

```bash
# Status de tous les conteneurs
cd /home/adr3bot/bot/media-stack/vps && docker compose ps

# Logs d'un service (temps reel)
docker logs -f sonarr
docker logs -f rclone --tail 100

# Redemarrer un service
docker compose restart sonarr

# Redemarrer toute la stack
docker compose down && docker compose up -d

# Entrer dans un conteneur
docker exec -it sonarr /bin/bash

# Mettre a jour les images et redemarrer
docker compose pull && docker compose up -d

# Nettoyer images/volumes/networks inutilises
docker system prune -af --volumes
```

### WireGuard (tunnel VPS -- Freebox)

```bash
# Voir l'etat du tunnel
wg show wg-freebox

# Demarrer / arreter le tunnel
wg-quick up wg-freebox
wg-quick down wg-freebox

# Activer au demarrage
systemctl enable wg-quick@wg-freebox

# Tester la connectivite vers la Freebox
ping -c 3 <FREEBOX_WG_IP>
```

### Nginx

```bash
# Tester la configuration
nginx -t

# Recharger apres modification
nginx -t && systemctl reload nginx

# Logs d'acces et d'erreur
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
```

### Fail2ban

```bash
# Status general
docker exec fail2ban fail2ban-client status

# Status d'une jail specifique
docker exec fail2ban fail2ban-client status sshd
docker exec fail2ban fail2ban-client status nginx-auth

# Debanner une IP
docker exec fail2ban fail2ban-client set sshd unbanip <IP>
docker exec fail2ban fail2ban-client set nginx-auth unbanip <IP>

# Bannir manuellement une IP
docker exec fail2ban fail2ban-client set sshd banip <IP>
```

### Systeme

```bash
# Espace disque
df -h
df -h /mnt/HC_Volume_104978745
du -sh /mnt/HC_Volume_104978745/downloads/* /mnt/HC_Volume_104978745/media/*

# Processus
htop
docker stats

# Memoire
free -h

# Logs systeme
journalctl -u docker --since "1 hour ago"
```

---

## 2. Monitoring

### Verifier que le VPN fonctionne

Le conteneur Gluetun a un healthcheck integre qui verifie l'IP publique via `ipinfo.io`.

```bash
# Verifier l'IP vue par qBittorrent (doit etre Mullvad, PAS l'IP du VPS)
docker exec gluetun wget -qO- https://ipinfo.io/json

# Verifier le healthcheck Gluetun
docker inspect --format='{{.State.Health.Status}}' gluetun
# Attendu : "healthy"
```

Si l'IP retournee est celle du VPS, **arreter immediatement qBittorrent** :

```bash
docker compose stop qbittorrent
```

### Verifier le tunnel WireGuard

```bash
# Etat complet du tunnel
wg show wg-freebox
```

Points a verifier dans la sortie :

| Champ | Valeur attendue |
|---|---|
| `latest handshake` | Moins de 2 minutes |
| `transfer` | Octets envoyes/recus croissants |
| `endpoint` | IP publique de la Freebox |
| `allowed ips` | IP WireGuard de la Freebox (`/32`) |

Si `latest handshake` est absent ou superieur a 5 minutes, le tunnel est down.

### Verifier la sync rclone

```bash
# Logs du conteneur rclone (move toutes les minutes)
docker logs rclone --tail 50

# Verifier la derniere sync reussie
docker logs rclone 2>&1 | grep "Sync termine"

# Si sync-watch.sh est actif
tail -50 /var/log/rclone-sync.log
```

### Verifier les services

```bash
# Vue d'ensemble
docker compose ps

# Verifier qu'aucun conteneur n'est en restart loop
docker compose ps --format "table {{.Name}}\t{{.Status}}" | grep -i restarting
```

| Service | Port local | Healthcheck |
|---|---|---|
| gluetun | - | Oui (`wget ipinfo.io`) |
| qbittorrent | 8080 (via gluetun) | Non (depend de gluetun) |
| prowlarr | 9696 | Oui (`curl /ping`) |
| sonarr | 8989 | Non |
| radarr | 7878 | Non |
| overseerr | 5055 | Non |
| homepage | 7575 | Non |
| rclone | - | Non |
| fail2ban | host | Non |
| dozzle | 9999 | Non |
| notifiarr | 5454 | Non |
| byparr | 8192 | Non |
| watchtower | - | Non |

### Verifier fail2ban

```bash
# Nombre de bans actifs par jail
docker exec fail2ban fail2ban-client status sshd
docker exec fail2ban fail2ban-client status nginx-auth
```

Configuration des jails :

| Jail | Seuil | Duree du ban | Fichier de log surveille |
|---|---|---|---|
| `sshd` | 3 echecs en 10 min | 24 heures | `/var/log/auth.log` |
| `nginx-auth` | 5 echecs en 10 min | 1 heure | `/var/log/nginx/error.log` |

---

## 3. Maintenance

### Mise a jour des images Docker

**Automatique (Watchtower)** : les images sont mises a jour automatiquement tous les jours a 3h du matin. Watchtower supprime les anciennes images apres mise a jour (`WATCHTOWER_CLEANUP=true`).

```bash
# Voir les dernieres mises a jour effectuees par Watchtower
docker logs watchtower --tail 30

# Forcer une verification manuelle
docker exec watchtower /watchtower --run-once
```

**Manuelle** :

```bash
cd /home/adr3bot/bot/media-stack/vps

# Mettre a jour toutes les images
docker compose pull

# Redemarrer avec les nouvelles images
docker compose up -d

# Nettoyer les anciennes images
docker image prune -f
```

### Mise a jour systeme

Les mises a jour de securite sont installees automatiquement via `unattended-upgrades` (configure par `harden.sh`).

```bash
# Verifier le statut
systemctl status unattended-upgrades

# Voir les dernieres mises a jour appliquees
cat /var/log/unattended-upgrades/unattended-upgrades.log

# Lancer une mise a jour manuelle
apt update && apt upgrade -y
```

### Rotation des logs

Le daemon Docker est configure pour limiter les logs a 10 Mo par conteneur, 3 fichiers maximum (configure dans `/etc/docker/daemon.json` par `harden.sh`).

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Pour les logs systeme :

```bash
# Verifier la taille des logs Docker
du -sh /var/lib/docker/containers/*/

# Verifier les logs systeme
journalctl --disk-usage

# Nettoyer les vieux logs systeme (garder 7 jours)
journalctl --vacuum-time=7d
```

### Nettoyage espace disque

```bash
# Verifier le volume Hetzner
df -h /mnt/HC_Volume_104978745

# Voir ce qui prend de la place
du -sh /mnt/HC_Volume_104978745/downloads/* /mnt/HC_Volume_104978745/media/*

# Nettoyer les telechargements incomplets
rm -rf /mnt/HC_Volume_104978745/downloads/incomplete/*

# Nettoyer Docker (images, conteneurs arretes, volumes orphelins)
docker system prune -af --volumes

# Voir les plus gros fichiers dans downloads
find /mnt/HC_Volume_104978745/downloads -type f -size +1G -exec ls -lh {} \; | sort -k5 -h
```

### Renouvellement certificats SSL Cloudflare

Les certificats origin Cloudflare ont une duree de vie de 15 ans par defaut. Si un renouvellement est necessaire :

1. Cloudflare Dashboard -- SSL/TLS -- Origin Server
2. Creer un nouveau certificat
3. Remplacer les fichiers sur le VPS :

```bash
# Remplacer les certificats
nano /etc/ssl/cloudflare/cert.pem
nano /etc/ssl/cloudflare/key.pem

# Recharger nginx
nginx -t && systemctl reload nginx
```

### Rotation cles WireGuard Mullvad

Pour renouveler la cle WireGuard Mullvad (utilisee par Gluetun pour les torrents) :

1. Generer une nouvelle cle sur le compte Mullvad
2. Mettre a jour le `.env` du VPS :

```bash
nano /home/adr3bot/bot/media-stack/vps/.env
# Modifier WIREGUARD_PRIVATE_KEY et WIREGUARD_ADDRESSES
```

3. Redemarrer Gluetun :

```bash
cd /home/adr3bot/bot/media-stack/vps && docker compose restart gluetun
```

4. Verifier que le VPN fonctionne :

```bash
docker exec gluetun wget -qO- https://ipinfo.io/json
```

---

## 4. Troubleshooting

### rclone "key is unknown"

**Symptome** : le conteneur rclone echoue avec `Host key verification failed` ou `key is unknown`.

**Diagnostic** :

```bash
docker logs rclone --tail 20
# Verifier que known_hosts existe
ls -la /home/adr3bot/bot/media-stack/vps/config/rclone/known_hosts
```

**Solution** :

```bash
# Rescanner la cle hote SFTP de la Freebox
ssh-keyscan -p 2222 -H <FREEBOX_WG_IP> > /home/adr3bot/bot/media-stack/vps/config/rclone/known_hosts

# Redemarrer rclone
cd /home/adr3bot/bot/media-stack/vps && docker compose restart rclone
```

Causes possibles :
- Le fichier `known_hosts` n'a pas ete genere (setup.sh non execute ou SFTP pas encore demarre)
- L'IP WireGuard de la Freebox a change
- Le conteneur SFTP a ete recree (nouvelle cle hote)

---

### qBittorrent ne demarre pas

**Symptome** : le conteneur `qbittorrent` reste en `waiting` ou redemarre en boucle.

**Diagnostic** :

```bash
# qBittorrent depend de gluetun healthy
docker inspect --format='{{.State.Health.Status}}' gluetun
docker logs gluetun --tail 30
```

**Solution** :

1. Si Gluetun n'est pas `healthy` :

```bash
# Verifier la cle WireGuard Mullvad
docker logs gluetun 2>&1 | grep -i "error\|failed"

# Redemarrer Gluetun
docker compose restart gluetun

# Attendre le healthcheck (jusqu'a 60s)
docker compose ps gluetun
```

2. Si Gluetun est healthy mais qBittorrent ne demarre pas :

```bash
docker logs qbittorrent --tail 30
# Verifier les permissions
ls -la /mnt/HC_Volume_104978745/downloads/
chown -R 1000:1000 /mnt/HC_Volume_104978745/downloads
```

---

### Sync ne fonctionne pas

**Symptome** : les fichiers n'arrivent pas sur la Freebox.

**Diagnostic** :

```bash
# 1. Verifier le tunnel WireGuard
wg show wg-freebox
ping -c 3 <FREEBOX_WG_IP>

# 2. Tester le SFTP manuellement
ssh -p 2222 -i /home/adr3bot/bot/media-stack/vps/config/rclone/id_rsa mediastack@<FREEBOX_WG_IP>

# 3. Verifier les logs rclone
docker logs rclone --tail 30
```

**Solution selon la cause** :

| Cause | Solution |
|---|---|
| Tunnel WireGuard down | `wg-quick down wg-freebox && wg-quick up wg-freebox` |
| SFTP inaccessible | Verifier que le conteneur `sftp` tourne sur la Freebox |
| Cle SSH invalide | Recopier la cle publique dans `freebox/config/sftp/ssh/authorized_key` |
| Permissions | `chown -R 1000:1000 /mnt/HC_Volume_104978745/media` sur le VPS |

---

### Service inaccessible via HTTPS

**Symptome** : erreur 502, 503, timeout ou certificat invalide en accedant a un sous-domaine.

**Diagnostic** :

```bash
# 1. Verifier que le conteneur tourne
docker compose ps <service>

# 2. Tester le port local
curl -s http://127.0.0.1:<port>
# Ports : sonarr=8989, radarr=7878, prowlarr=9696, overseerr=5055, homepage=7575 (->3000), qbittorrent=8080

# 3. Tester la config nginx
nginx -t

# 4. Verifier les certificats SSL
openssl x509 -in /etc/ssl/cloudflare/cert.pem -noout -dates
```

**Solution** :

| Cause | Solution |
|---|---|
| Conteneur down | `docker compose restart <service>` |
| nginx config invalide | `nginx -t` pour voir l'erreur, corriger, puis `systemctl reload nginx` |
| Certificat expire | Regenerer dans Cloudflare Dashboard, remplacer les fichiers |
| DNS non configure | Ajouter le A record dans Cloudflare (proxy ON) |
| Cloudflare SSL mode | Verifier que le mode SSL est `Full` dans Cloudflare (pas strict avec Origin Cert) |

---

### Fail2ban ban accidentel

**Symptome** : impossible de se connecter en SSH ou aux services web depuis sa propre IP.

**Diagnostic** :

```bash
# Verifier si son IP est bannee (depuis un autre acces, ex: console Hetzner)
docker exec fail2ban fail2ban-client status sshd
docker exec fail2ban fail2ban-client status nginx-auth
```

**Solution** :

```bash
# Debanner son IP
docker exec fail2ban fail2ban-client set sshd unbanip <MON_IP>
docker exec fail2ban fail2ban-client set nginx-auth unbanip <MON_IP>
```

Pour eviter que ca se reproduise, on peut whitelister son IP :

```bash
# Editer jail.local
nano /home/adr3bot/bot/media-stack/vps/fail2ban/jail.local
# Ajouter sous [DEFAULT] :
# ignoreip = 127.0.0.1/8 <MON_IP>

# Redemarrer fail2ban
docker compose restart fail2ban
```

---

### Fichiers absents sur la Freebox

**Symptome** : les fichiers synchronises ne sont pas visibles sur le NVMe de la Freebox.

**Diagnostic** :

```bash
# Sur la Freebox, verifier que les fichiers sont presents
ls -la /mnt/NVMe/media/films/
ls -la /mnt/NVMe/media/series/

# Verifier les permissions
stat /mnt/NVMe/media/films/<un_fichier>
```

**Solution** :

1. **Fichiers absents** : la sync rclone n'a pas fonctionne -- voir [Sync ne fonctionne pas](#sync-ne-fonctionne-pas)
2. **Permissions incorrectes** : `chown -R 1000:1000 /mnt/NVMe/media`
3. **Sync incomplete** : verifier les logs rclone, les fichiers `.part` ou `.!qB` sont exclus de la sync

---

### Espace disque plein

**Symptome** : services qui plantent, ecritures impossibles, erreurs `No space left on device`.

**Diagnostic** :

```bash
df -h /mnt/HC_Volume_104978745
du -sh /mnt/HC_Volume_104978745/downloads/* /mnt/HC_Volume_104978745/media/* /var/lib/docker/*
```

**Solution** :

```bash
# 1. Nettoyer les telechargements incomplets
rm -rf /mnt/HC_Volume_104978745/downloads/incomplete/*

# 2. Supprimer les fichiers seedees termines (verifier d'abord dans qBittorrent)
# Ne supprimer QUE les fichiers qui ont ete synces vers la Freebox

# 3. Nettoyer Docker
docker system prune -af --volumes

# 4. Nettoyer les logs systeme
journalctl --vacuum-time=3d

# 5. Trouver les plus gros fichiers
find /mnt/HC_Volume_104978745 -type f -size +1G -exec ls -lh {} \; 2>/dev/null | sort -k5 -h
```

---

### WireGuard tunnel down

**Symptome** : la sync ne fonctionne plus, `wg show wg-freebox` ne montre pas de handshake recent.

**Diagnostic** :

```bash
wg show wg-freebox
# Verifier : latest handshake, endpoint, transfer
```

**Solution** :

```bash
# Redemarrer le tunnel
wg-quick down wg-freebox
wg-quick up wg-freebox

# Tester
ping -c 3 <FREEBOX_WG_IP>
```

Causes possibles :

| Cause | Verification | Solution |
|---|---|---|
| Endpoint change (IP publique Freebox) | `grep Endpoint /etc/wireguard/wg-freebox.conf` | Mettre a jour l'endpoint dans le fichier conf et `.env` |
| Cle expiree | Logs WireGuard | Regenerer la config sur la Freebox, mettre a jour `.env` et `/etc/wireguard/wg-freebox.conf` |
| MTU trop eleve | Paquets fragmentes, timeouts | Reduire le MTU (defaut : 1360 dans le setup) |
| Serveur WireGuard Freebox desactive | Verifier dans Freebox OS | Reactiver dans Parametres -- Serveur VPN -- WireGuard |

---

### Authelia ne fonctionne pas

**Symptome** : erreur 401, redirection en boucle, ou page d'auth inaccessible.

**Diagnostic** :

```bash
# Verifier que le conteneur Authelia tourne
docker ps | grep authelia
docker logs authelia --tail 30

# Verifier le healthcheck
docker inspect --format='{{.State.Health.Status}}' authelia

# Tester la config nginx
nginx -t
```

**Solution** :

```bash
# Redemarrer Authelia
docker compose restart authelia

# Si la base SQLite est corrompue, supprimer et redemarrer
rm vps/config/authelia/db.sqlite3
docker compose restart authelia

# Recharger nginx
nginx -t && systemctl reload nginx
```

Causes possibles :
- Conteneur Authelia non demarre ou crash
- Variables d'environnement `AUTHELIA_*` manquantes dans `.env`
- DNS `auth.DOMAIN` non configure dans Cloudflare
- Snippet nginx `authelia-authrequest.conf` mal deploye dans `/etc/nginx/snippets/`
- Nginx `default_server` manquant sur le bloc auth (cause erreur 525 Cloudflare)

### Cloudflare 525 SSL handshake failed

**Symptome** : erreur 525 sur un ou tous les sous-domaines, malgre SSL fonctionnel en local.

**Diagnostic** :

```bash
# Verifier que nginx ecoute sur 443
ss -tlnp | grep 443

# Verifier que le cert couvre le domaine
openssl x509 -in /etc/ssl/cloudflare/cert.pem -text -noout | grep -A2 "Subject Alternative Name"

# Tester SSL comme Cloudflare le ferait
openssl s_client -connect <VPS_IP>:443 -servername home.<DOMAIN> 2>&1 | head -20

# Verifier qu'il n'y a qu'UN seul fichier nginx pour le port 443
ls /etc/nginx/sites-enabled/
```

**Solution** :

| Cause | Solution |
|---|---|
| Pas de `default_server` | Ajouter `default_server` a `listen 443 ssl` du bloc auth dans media-stack |
| Plusieurs fichiers nginx SSL | Integrer tous les server blocks 443 dans un seul fichier (`media-stack`) |
| Mode Cloudflare SSL strict | Passer en mode "Full" (pas strict) dans Cloudflare SSL/TLS |
| Firewall bloque Cloudflare | Verifier `iptables -L INPUT -n` — le port 443 doit etre ouvert |

**Important** : tous les server blocks SSL port 443 doivent etre dans **un seul fichier nginx** pour eviter les conflits SSL avec Cloudflare.

### Services *arr affichent leur propre page de login

**Symptome** : apres authentification Authelia, Radarr/Sonarr/Prowlarr montrent encore leur page login interne.

**Solution** : desactiver l'auth interne en la passant en mode "External" :

```bash
# Radarr
sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' config/radarr/config.xml

# Sonarr
sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' config/sonarr/config.xml

# Prowlarr
sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' config/prowlarr/config.xml

# Redemarrer
docker restart radarr sonarr prowlarr
```

### Authelia — code de verification / TOTP

Avec le notifier `filesystem`, les codes de verification d'identite sont ecrits dans un fichier (pas envoyes par email) :

```bash
# Lire le code OTP
cat /home/adr3bot/bot/media-stack/vps/config/authelia/notification.txt
```

Le code est une chaine de 8 caracteres (ex: `PZ3U92QW`). Ne pas copier d'espaces ou de texte supplementaire.

Si rate limit atteint apres trop de tentatives :

```bash
docker restart authelia
# Attendre ~30s puis retenter
```

---

## 5. Sync avancee (sync-watch.sh)

Le script `vps/scripts/sync-watch.sh` offre une alternative a la sync rclone en boucle (toutes les minutes). Il utilise `inotify` pour detecter les nouveaux fichiers en temps reel.

### Differences avec le conteneur rclone

| | Conteneur rclone | sync-watch.sh |
|---|---|---|
| Methode | Boucle `rclone move` toutes les minutes | Detection inotify + sync fichier par fichier |
| Latence | Jusqu'a 1 min | Quasi instantanee (+ 30s stabilisation) |
| Execution | Conteneur Docker | Script sur le host |
| Fallback | - | Sync complete toutes les heures |
| Retry | Aucun | 3 tentatives avec backoff (10s, 30s, 90s) |
| Notifications | Non | Webhook Discord/Slack |

### Activer la sync temps reel

```bash
# Prerequis : inotify-tools (installe par setup.sh)
apt install inotify-tools

# Lancer en arriere-plan
cd /home/adr3bot/bot/media-stack/vps
nohup bash scripts/sync-watch.sh &

# Ou creer un service systemd
cat > /etc/systemd/system/sync-watch.service << 'EOF'
[Unit]
Description=Media Stack Sync Watch
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=/home/adr3bot/bot/media-stack/vps
ExecStart=/bin/bash scripts/sync-watch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sync-watch
```

### Configuration inotify

Le script surveille `/mnt/HC_Volume_104978745/media` recursivement pour les evenements `close_write` et `moved_to`. Les fichiers temporaires (`.part`, `.tmp`, `.!qB`, `~`) sont ignores.

Si le nombre de fichiers est important, augmenter la limite inotify :

```bash
# Voir la limite actuelle
cat /proc/sys/fs/inotify/max_user_watches

# Augmenter si necessaire
echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.d/99-inotify.conf
sysctl -p /etc/sysctl.d/99-inotify.conf
```

### Logs et debug

```bash
# Voir les logs
tail -f /var/log/rclone-sync.log

# Verifier que le processus tourne
pgrep -f sync-watch

# Verifier les notifications webhook
grep "webhook\|FAILED" /var/log/rclone-sync.log
```

---

## 6. Sauvegardes

### Ce qu'il faut sauvegarder

| Element | Chemin | Raison |
|---|---|---|
| Variables d'environnement VPS | `vps/.env` | Contient toutes les cles et mots de passe |
| Variables d'environnement Freebox | `freebox/.env` | Config Freebox SFTP |
| Cle SSH rclone | `vps/config/rclone/id_rsa` | Authentification SFTP |
| Config WireGuard | `/etc/wireguard/wg-freebox.conf` | Tunnel VPS-Freebox |
| Config Sonarr | `vps/config/sonarr/` | Series suivies, profils, historique |
| Config Radarr | `vps/config/radarr/` | Films suivis, profils, historique |
| Config Prowlarr | `vps/config/prowlarr/` | Indexeurs configures |
| Config Overseerr | `vps/config/overseerr/` | Utilisateurs, demandes |
| Config qBittorrent | `vps/config/qbittorrent/` | Torrents actifs, preferences |
| Config Homepage | `vps/config/homepage/` | Dashboard personnalise |
| Config Notifiarr | `vps/config/notifiarr/` | Notifications et integrations |
| Config Authelia | `vps/config/authelia/` | SSO, base utilisateurs, sessions |
| Certificats SSL | `/etc/ssl/cloudflare/` | Certificats origin Cloudflare |

### Ce qu'il ne faut PAS sauvegarder

- `/mnt/HC_Volume_104978745/downloads/` -- fichiers temporaires de telechargement, volumineux et reproductibles
- `/mnt/HC_Volume_104978745/media/` -- media synces, reproductibles depuis les sources
- `/var/lib/docker/` -- runtime Docker, recree automatiquement
- `vps/config/gluetun/` -- cache Gluetun, recree au demarrage
- `fail2ban_data` volume -- base de bans, ephemere

### Script de backup recommande

```bash
#!/usr/bin/env bash
# backup-media-stack.sh — Sauvegarde des configs critiques
set -euo pipefail

BACKUP_DIR="/root/backups/media-stack"
DATE=$(date +%Y-%m-%d_%H%M)
BACKUP_FILE="${BACKUP_DIR}/media-stack-${DATE}.tar.gz"
PROJECT_DIR="/home/adr3bot/bot/media-stack"
VOLUME="/mnt/HC_Volume_104978745"

mkdir -p "$BACKUP_DIR"

tar czf "$BACKUP_FILE" \
    -C / \
    home/adr3bot/bot/media-stack/vps/.env \
    home/adr3bot/bot/media-stack/freebox/.env \
    home/adr3bot/bot/media-stack/vps/config/rclone/id_rsa \
    home/adr3bot/bot/media-stack/vps/config/rclone/id_rsa.pub \
    home/adr3bot/bot/media-stack/vps/config/rclone/known_hosts \
    home/adr3bot/bot/media-stack/vps/config/sonarr/ \
    home/adr3bot/bot/media-stack/vps/config/radarr/ \
    home/adr3bot/bot/media-stack/vps/config/prowlarr/ \
    home/adr3bot/bot/media-stack/vps/config/overseerr/ \
    home/adr3bot/bot/media-stack/vps/config/qbittorrent/ \
    home/adr3bot/bot/media-stack/vps/config/homepage/ \
    home/adr3bot/bot/media-stack/vps/config/notifiarr/ \
    home/adr3bot/bot/media-stack/vps/config/authelia/ \
    etc/wireguard/wg-freebox.conf \
    etc/ssl/cloudflare/ \
    2>/dev/null || true

# Garder les 7 derniers backups
ls -t "${BACKUP_DIR}"/media-stack-*.tar.gz | tail -n +8 | xargs rm -f 2>/dev/null || true

echo "Backup cree : ${BACKUP_FILE}"
echo "Taille : $(du -h "$BACKUP_FILE" | cut -f1)"
```

Automatiser avec cron :

```bash
# Backup quotidien a 4h du matin
echo "0 4 * * * /root/backup-media-stack.sh >> /var/log/backup-media-stack.log 2>&1" | crontab -
```

---

## 7. Procedures d'urgence

### VPS compromis

**Symptomes** : processus inconnus, fichiers modifies, trafic suspect, acces non autorise dans les logs.

**Actions immediates** :

```bash
# 1. Couper les services pour limiter l'exposition
cd /home/adr3bot/bot/media-stack/vps && docker compose down

# 2. Couper le tunnel WireGuard (proteger la Freebox)
wg-quick down wg-freebox

# 3. Changer le port SSH et les cles si possible
# (depuis la console Hetzner si SSH compromis)

# 4. Examiner les logs
journalctl --since "24 hours ago"
last -100
cat /var/log/auth.log | grep "Accepted\|Failed"
docker logs fail2ban --tail 100
```

**Actions de remediation** :

1. Sauvegarder les configs (`.env`, configs des services)
2. Recreer le VPS depuis zero via Hetzner
3. Reinstaller avec `setup.sh` + `harden.sh`
4. Changer **tous** les mots de passe et cles :
   - Mot de passe Authelia (`AUTHELIA_PASSWORD`) et secrets (`AUTHELIA_JWT_SECRET`, etc.)
   - Cle WireGuard Mullvad
   - Cle WireGuard tunnel Freebox
   - Cle SSH rclone (regenerer + recopier sur la Freebox)
   - Cle de chiffrement Homepage
5. Regenerer les certificats Cloudflare origin
6. Verifier que la Freebox n'a pas ete affectee

---

### IP du VPS leakee

**Symptome** : attaques directes sur l'IP du VPS (DDoS, scans), services accessibles sans passer par Cloudflare.

**Verification** :

```bash
# Verifier que les DNS passent bien par Cloudflare
dig +short sonarr.<DOMAIN>
# Doit retourner une IP Cloudflare, PAS l'IP du VPS

# Verifier les connexions directes
cat /var/log/nginx/access.log | grep -v "cloudflare" | head
```

**Mitigation** :

1. **Hetzner Firewall** : verifier que seuls les ports 80, 443, SSH custom et UDP WireGuard sont ouverts
2. **Cloudflare** : activer "Under Attack Mode" temporairement si DDoS
3. **nginx** : ajouter une restriction pour n'accepter que les IP Cloudflare :

```nginx
# Ajouter dans chaque bloc server
# Liste des IP Cloudflare : https://www.cloudflare.com/ips/
allow 173.245.48.0/20;
allow 103.21.244.0/22;
# ... (ajouter toutes les plages Cloudflare)
deny all;
```

4. **Si necessaire** : changer l'IP du VPS (Hetzner permet de commander une nouvelle IP) et mettre a jour les DNS Cloudflare

---

### IP publique de la Freebox changee

**Symptome** : le tunnel WireGuard ne se reconnecte plus, la sync rclone echoue.

**Diagnostic** :

```bash
wg show wg-freebox
# L'endpoint affiche ne correspond plus a l'IP publique actuelle de la Freebox
```

**Solution** :

1. Obtenir la nouvelle IP publique de la Freebox (depuis Freebox OS ou un site comme `ifconfig.me` depuis le reseau local)

2. Mettre a jour la config WireGuard :

```bash
# Editer le fichier
nano /etc/wireguard/wg-freebox.conf
# Modifier la ligne Endpoint = <NOUVELLE_IP>:<PORT>

# Mettre a jour le .env aussi
nano /home/adr3bot/bot/media-stack/vps/.env
# Modifier WG_FREEBOX_ENDPOINT=<NOUVELLE_IP>
```

3. Redemarrer le tunnel :

```bash
wg-quick down wg-freebox
wg-quick up wg-freebox

# Verifier
ping -c 3 <FREEBOX_WG_IP>
```

**Prevention** : configurer un DDNS sur la Freebox (Freebox OS -- Parametres -- Nom de domaine) et utiliser le hostname au lieu de l'IP dans l'endpoint WireGuard.
