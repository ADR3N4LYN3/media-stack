# Troubleshooting — Bugs rencontrés et solutions

Historique des problèmes rencontrés lors du déploiement, avec diagnostic et solution.

---

## 1. rclone — "knownhosts: key is unknown"

**Date** : 2026-03-05

**Symptôme** :
```
CRITICAL: Failed to create file system for "freebox:/data": NewFs: couldn't connect SSH: ssh: handshake failed: knownhosts: key is unknown
```

**Cause** : Le fichier `known_hosts` référencé dans `rclone.conf` était vide (0 bytes). Le `ssh-keyscan` avait été exécuté dans le mauvais répertoire (`~/bot/media-stack/vps/config/rclone/` au lieu de `./config/rclone/`).

**Solution** :
```bash
source .env
ssh-keyscan -p 2222 $FREEBOX_WG_IP > config/rclone/known_hosts
docker compose up -d --force-recreate rclone
```

---

## 2. rclone — SFTP inaccessible (100% packet loss)

**Date** : 2026-03-05

**Symptôme** :
```
ping 192.168.27.64 → 100% packet loss
nc -zv 192.168.27.64 2222 → Connection timed out
```

**Cause** : `FREEBOX_WG_IP` dans `.env` pointait vers l'IP WireGuard du **routeur Freebox** (`192.168.27.64`), mais le conteneur SFTP tourne sur la **VM** (RustDesk) qui a une IP LAN différente (`192.168.1.250`). Le tunnel WireGuard route les paquets vers le routeur, pas vers la VM directement.

**Diagnostic** :
```bash
# Sur la VM Freebox
hostname -I  # → 192.168.1.250

# Depuis le VPS (via tunnel, allowed IPs inclut 192.168.1.0/24)
nc -zv 192.168.1.250 2222  # → open
```

**Solution** :
```bash
# Corriger l'IP dans .env du VPS
sed -i 's/FREEBOX_WG_IP=192.168.27.64/FREEBOX_WG_IP=192.168.1.250/' .env

# Regénérer rclone.conf et known_hosts
source .env
sed -e "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
    -e "s|FREEBOX_SFTP_USER_PLACEHOLDER|${FREEBOX_SFTP_USER}|g" \
    -e "s|FREEBOX_SFTP_PORT_PLACEHOLDER|${FREEBOX_SFTP_PORT}|g" \
    config/rclone/rclone.conf.template > config/rclone/rclone.conf

ssh-keyscan -p 2222 $FREEBOX_WG_IP > config/rclone/known_hosts
docker compose up -d --force-recreate rclone
```

**Prevention** : Le commentaire dans `.env.example` a été mis à jour pour préciser d'utiliser l'IP LAN de la VM et non l'IP WireGuard du routeur.

---

## 3. FlareSolverr/Byparr — "blocked by CloudFlare Protection" malgré challenge résolu

**Date** : 2026-03-05 (mis à jour 2026-03-06)

**Symptôme** : FlareSolverr résout les challenges Cloudflare (logs : "Challenge solved!", 200 OK) mais Prowlarr affiche toujours "Unable to access X, blocked by CloudFlare Protection" pour tous les indexeurs (1337x, Cpasbien, TorrentGalaxy, EZTV).

**Cause** : Bug architectural de Prowlarr (issues #2572, #2360, #2577, FlareSolverr #1672) :
1. Prowlarr envoie la requête à FlareSolverr
2. FlareSolverr résout le challenge, retourne cookies `cf_clearance` + HTML
3. **Prowlarr JETTE le body HTML**
4. Prowlarr refait une 2ème requête HTTP avec les cookies mais ajoute ses propres headers (`Accept-Encoding: gzip`)
5. Cloudflare détecte l'incohérence entre le cookie et les headers → 403

Jackett n'a PAS ce problème car il utilise directement le HTML retourné.

**Solution** : Remplacer FlareSolverr par **Byparr** (drop-in replacement utilisant Camoufox, Firefox-based) :
```yaml
byparr:
  image: ghcr.io/thephaseless/byparr:latest
  container_name: byparr
```
Proxy Prowlarr : `http://byparr:8191` (communication interne Docker)

**Note** : FlareSolverr reste en PM2 sur le host pour les autres bots qui l'utilisent. Byparr Docker est sur le port 8192 du host pour éviter le conflit.

---

## 4. Disque VPS à 100% — Migration vers Hetzner Volume

**Date** : 2026-03-06

**Symptôme** : Prowlarr disk I/O error, services instables, `/data` à 100%

**Cause** : Le disque système de 78GB était plein (55GB de downloads).

**Solution** :
- Ajout d'un Hetzner Volume de 250GB (XFS)
- Volume monté automatiquement à `/mnt/HC_Volume_104978745`
- Migration des données : `rsync -avP /data/ /mnt/HC_Volume_104978745/`
- Mise à jour du `.env` :
  ```
  DATA_PATH=/mnt/HC_Volume_104978745
  ```
- Nettoyage de l'ancien `/data/` : `rm -rf /data/downloads/*`
- Résultat : disque système de 100% → 24%

---

## 5. Radarr — Import échoué (path not accessible)

**Date** : 2026-03-06

**Symptôme** : `Import failed, path does not exist or is not accessible by Sonarr/Radarr`

**Cause** : Les volumes Docker ne montaient que `${DOWNLOADS_PATH}/complete:/downloads/complete` mais les fichiers étaient dans `/downloads/incomplete` (en cours de téléchargement par qBittorrent).

**Solution** : Changer le volume mount pour monter le répertoire complet :
```yaml
# Avant
- ${DOWNLOADS_PATH}/complete:/downloads/complete

# Après
- ${DOWNLOADS_PATH}:/downloads
```

---

## 6. Homepage — Erreur API widget disque volume

**Date** : 2026-03-06

**Symptôme** : "Erreur API" sur le widget resources de Homepage pour le volume Hetzner

**Cause** : Le conteneur Homepage n'avait pas accès au point de montage du volume.

**Solution** :
1. Ajouter le volume mount dans docker-compose :
```yaml
- /mnt/HC_Volume_104978745:/mnt/HC_Volume_104978745:ro
```
2. Utiliser deux blocs `- resources:` séparés dans widgets.yaml (pas une liste) :
```yaml
- resources:
    cpu: true
    memory: true
    disk: /
- resources:
    disk: /mnt/HC_Volume_104978745
```

---

## 7. FlareSolverr/Byparr — Prowlarr "blocked by CloudFlare" malgré 200 OK

**Date** : 2026-03-06

**Symptôme** : FlareSolverr retourne 200 OK ("Challenge not detected!") mais Prowlarr affiche "Unable to access X, blocked by CloudFlare Protection"

**Cause** : Bug architectural de Prowlarr (issues #2572, #2360, #2577, FlareSolverr #1672) :
1. Prowlarr envoie la requête à FlareSolverr
2. FlareSolverr résout le challenge, retourne cookies cf_clearance + HTML
3. **Prowlarr JETTE le body HTML**
4. Prowlarr refait une 2ème requête HTTP avec les cookies mais ajoute ses propres headers (Accept-Encoding: gzip)
5. Cloudflare détecte l'incohérence entre le cookie et les headers → 403

Jackett n'a PAS ce problème car il utilise directement le HTML retourné.

**Solution** : Remplacer FlareSolverr par **Byparr** (drop-in replacement) :
```yaml
byparr:
  image: ghcr.io/thephaseless/byparr:latest
  container_name: byparr
```
Proxy Prowlarr : `http://byparr:8191`

**Note** : FlareSolverr reste en PM2 sur le host pour les autres bots qui l'utilisent. Byparr Docker est sur le port 8192 du host pour éviter le conflit.

---

## 8. Hardlinks impossibles — Sonarr/Radarr copie au lieu de hardlinker

**Date** : 2026-03-06

**Symptôme** : Les fichiers dans `/media/` sont des copies (pas des hardlinks). Après rclone move + seeding, l'espace disque est doublé. Les torrents finis restent "queued" dans Sonarr/Radarr.

**Cause** : Sonarr/Radarr montaient `${DOWNLOADS_PATH}:/downloads` et `${MEDIA_PATH}:/tv` (ou `/movies`) comme des volumes **séparés**. Docker voit deux montages distincts → hardlink impossible → copie automatique.

**Diagnostic** :
```bash
# Vérifier le nombre de liens d'un fichier (1 = copie, 2+ = hardlink)
stat /mnt/HC_Volume_104978745/media/films/*/* | grep Links
```

**Solution** : Monter un **volume unique** `/data` dans qBittorrent, Sonarr et Radarr :
```yaml
# docker-compose.yml — AVANT (hardlinks impossibles)
volumes:
  - ${DOWNLOADS_PATH}:/downloads
  - ${MEDIA_PATH}/series:/tv

# APRÈS (hardlinks fonctionnent)
volumes:
  - ${DATA_PATH}:/data
```

`.env` :
```
DATA_PATH=/mnt/HC_Volume_104978745
```

**Reconfiguration requise dans les WebUI** :
- **qBittorrent** : Save path → `/data/downloads/incomplete/{category}`
- **Sonarr** : Root Folder → `/data/media/series`
- **Radarr** : Root Folder → `/data/media/films`
- **Sonarr/Radarr** : Download Client > qBittorrent > **Remove Completed** ✅

---

## Réseau — Rappel des IPs

| Ressource | IP | Port |
|---|---|---|
| VM Freebox (SFTP) | 192.168.1.250 | 2222 |
| Routeur Freebox (WireGuard) | 192.168.27.64 | 22563 |
| Gateway Docker `vps_media_network` | 172.20.0.1 | — |
| Gateway Docker `bridge` (docker0) | 172.17.0.1 | — |
| FlareSolverr (PM2, pour autres bots) | localhost | 8191 |
| Byparr (Docker, pour Prowlarr) | byparr (réseau Docker) | 8191 (host: 8192) |
| Hetzner Volume | /mnt/HC_Volume_104978745 | — |
