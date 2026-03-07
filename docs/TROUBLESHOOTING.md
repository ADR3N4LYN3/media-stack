# Troubleshooting — Bugs rencontres et solutions

Historique des problemes rencontres lors du deploiement, avec diagnostic et solution.

> **Voir aussi** : [OPS.md](OPS.md) pour les procedures de depannage generiques et les commandes de reference.

---

## 1. rclone — "knownhosts: key is unknown"

**Date** : 2026-03-05

**Symptome** :
```
CRITICAL: Failed to create file system for "freebox:/data": NewFs: couldn't connect SSH: ssh: handshake failed: knownhosts: key is unknown
```

**Cause** : Le fichier `known_hosts` reference dans `rclone.conf` etait vide (0 bytes). Le `ssh-keyscan` avait ete execute dans le mauvais repertoire.

**Solution** :
```bash
source .env
ssh-keyscan -p 2222 $FREEBOX_WG_IP > config/rclone/known_hosts
docker compose up -d --force-recreate rclone
```

---

## 2. rclone — SFTP inaccessible (100% packet loss)

**Date** : 2026-03-05

**Symptome** :
```
ping 192.168.27.64 -> 100% packet loss
nc -zv 192.168.27.64 2222 -> Connection timed out
```

**Cause** : `FREEBOX_WG_IP` dans `.env` pointait vers l'IP WireGuard du **routeur Freebox** (`192.168.27.64`), mais le conteneur SFTP tourne sur la **VM** qui a une IP LAN differente (`192.168.1.250`). Le tunnel WireGuard route les paquets vers le routeur, pas vers la VM directement.

**Diagnostic** :
```bash
# Sur la VM Freebox
hostname -I  # -> 192.168.1.250

# Depuis le VPS (via tunnel, allowed IPs inclut 192.168.1.0/24)
nc -zv 192.168.1.250 2222  # -> open
```

**Solution** :
```bash
# Corriger l'IP dans .env du VPS
sed -i 's/FREEBOX_WG_IP=192.168.27.64/FREEBOX_WG_IP=192.168.1.250/' .env

# Regenerer rclone.conf et known_hosts
source .env
sed -e "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
    -e "s|FREEBOX_SFTP_USER_PLACEHOLDER|${FREEBOX_SFTP_USER}|g" \
    -e "s|FREEBOX_SFTP_PORT_PLACEHOLDER|${FREEBOX_SFTP_PORT}|g" \
    config/rclone/rclone.conf.template > config/rclone/rclone.conf

ssh-keyscan -p 2222 $FREEBOX_WG_IP > config/rclone/known_hosts
docker compose up -d --force-recreate rclone
```

**Prevention** : Le commentaire dans `.env.example` a ete mis a jour pour preciser d'utiliser l'IP LAN de la VM et non l'IP WireGuard du routeur.

---

## 3. Prowlarr — "blocked by CloudFlare Protection" malgre challenge resolu

**Date** : 2026-03-05 (mis a jour 2026-03-06)

**Symptome** : FlareSolverr resout les challenges Cloudflare (logs : "Challenge solved!", 200 OK) mais Prowlarr affiche toujours "Unable to access X, blocked by CloudFlare Protection" pour tous les indexeurs (1337x, Cpasbien, TorrentGalaxy, EZTV).

Variante : FlareSolverr retourne 200 OK ("Challenge not detected!") mais Prowlarr bloque quand meme.

**Cause** : Bug architectural de Prowlarr (issues #2572, #2360, #2577, FlareSolverr #1672) :
1. Prowlarr envoie la requete a FlareSolverr
2. FlareSolverr resout le challenge, retourne cookies `cf_clearance` + HTML
3. **Prowlarr JETTE le body HTML**
4. Prowlarr refait une 2eme requete HTTP avec les cookies mais ajoute ses propres headers (`Accept-Encoding: gzip`)
5. Cloudflare detecte l'incoherence entre le cookie et les headers -> 403

Jackett n'a PAS ce probleme car il utilise directement le HTML retourne. C'est pourquoi Jackett est maintenu dans la stack comme fallback pour les indexeurs proteges par Cloudflare.

**Solution** : Remplacer FlareSolverr par **Byparr** (drop-in replacement utilisant Camoufox, Firefox-based) :
```yaml
byparr:
  image: ghcr.io/thephaseless/byparr:latest
  container_name: byparr
```
Proxy Prowlarr : `http://byparr:8191` (communication interne Docker)

**Note** : FlareSolverr reste en PM2 sur le host pour les autres bots qui l'utilisent. Byparr Docker est sur le port 8192 du host pour eviter le conflit.

---

## 4. Disque VPS a 100% — Migration vers Hetzner Volume

**Date** : 2026-03-06

**Symptome** : Prowlarr disk I/O error, services instables, `/data` a 100%

**Cause** : Le disque systeme de 78GB etait plein (55GB de downloads).

**Solution** :
- Ajout d'un Hetzner Volume de 250GB (XFS)
- Volume monte automatiquement au chemin configure dans `DATA_PATH`
- Migration des donnees : `rsync -avP /data/ ${DATA_PATH}/`
- Mise a jour du `.env` :
  ```
  DATA_PATH=/chemin/vers/volume
  ```
- Nettoyage de l'ancien `/data/` : `rm -rf /data/downloads/*`
- Resultat : disque systeme de 100% -> 24%

---

## 5. Radarr — Import echoue (path not accessible)

**Date** : 2026-03-06

**Symptome** : `Import failed, path does not exist or is not accessible by Sonarr/Radarr`

**Cause** : Les volumes Docker ne montaient que `${DOWNLOADS_PATH}/complete:/downloads/complete` mais les fichiers etaient dans `/downloads/incomplete` (en cours de telechargement par qBittorrent).

**Solution** : Changer le volume mount pour monter le repertoire complet :
```yaml
# Avant
- ${DOWNLOADS_PATH}/complete:/downloads/complete

# Apres
- ${DOWNLOADS_PATH}:/downloads
```

---

## 6. Homepage — Erreur API widget disque volume

**Date** : 2026-03-06

**Symptome** : "Erreur API" sur le widget resources de Homepage pour le volume Hetzner

**Cause** : Le conteneur Homepage n'avait pas acces au point de montage du volume.

**Solution** :
1. Ajouter le volume mount dans docker-compose :
```yaml
- ${HETZNER_VOLUME_PATH}:${HETZNER_VOLUME_PATH}:ro
```
2. Utiliser deux blocs `- resources:` separes dans widgets.yaml (pas une liste) :
```yaml
- resources:
    cpu: true
    memory: true
    disk: /
- resources:
    disk: /mnt/HC_Volume_104978745
```

---

## 7. Hardlinks impossibles — Sonarr/Radarr copie au lieu de hardlinker

**Date** : 2026-03-06

**Symptome** : Les fichiers dans `/media/` sont des copies (pas des hardlinks). Apres rclone move + seeding, l'espace disque est double. Les torrents finis restent "queued" dans Sonarr/Radarr.

**Cause** : Sonarr/Radarr montaient `${DOWNLOADS_PATH}:/downloads` et `${MEDIA_PATH}:/tv` (ou `/movies`) comme des volumes **separes**. Docker voit deux montages distincts -> hardlink impossible -> copie automatique.

**Diagnostic** :
```bash
# Verifier le nombre de liens d'un fichier (1 = copie, 2+ = hardlink)
stat ${DATA_PATH}/media/films/*/* | grep Links
```

**Solution** : Monter un **volume unique** `/data` dans qBittorrent, Sonarr et Radarr :
```yaml
# docker-compose.yml — AVANT (hardlinks impossibles)
volumes:
  - ${DOWNLOADS_PATH}:/downloads
  - ${MEDIA_PATH}/series:/tv

# APRES (hardlinks fonctionnent)
volumes:
  - ${DATA_PATH}:/data
```

`.env` :
```
DATA_PATH=/chemin/vers/volume
```

**Reconfiguration requise dans les WebUI** :
- **qBittorrent** : Default Save Path -> `/data/downloads/complete`, Incomplete -> `/data/downloads/incomplete`
- **Sonarr** : Root Folder -> `/data/media/series` (supprimer l'ancien `/tv`)
- **Radarr** : Root Folder -> `/data/media/films` (supprimer l'ancien `/movies`)
- **Sonarr/Radarr** : Download Client > qBittorrent > **Remove Completed** actif
- **Series/films existants** : Mass Editor > Select All > Change Root Folder vers le nouveau chemin
- **Seerr** : Settings > Services > Radarr/Sonarr > Selectionner le nouveau dossier racine
- **Radarr** : Settings > Media Management > **Unmonitor Deleted Movies** actif (evite re-download apres rclone move)
- **qBittorrent** : Settings > BitTorrent > When ratio reaches `1.0` / seeding time `1440` min -> Stop torrent

---

## 8. qBittorrent — 502 Bad Gateway apres restart Gluetun

**Date** : 2026-03-06

**Symptome** : Apres un `docker compose restart gluetun`, qBittorrent affiche `healthy` dans `docker compose ps` mais le WebUI retourne 502 Bad Gateway. `curl http://127.0.0.1:8080` ne repond pas (code 000).

**Cause** : qBittorrent utilise `network_mode: service:gluetun` (stack reseau partagee). Quand Gluetun redemarre seul, Docker recree son interface reseau mais qBittorrent garde une reference vers l'ancien namespace reseau. Le port mapping `127.0.0.1:8080->8080` passe par Gluetun, donc qBit devient inaccessible.

**Solution** :
```bash
# Toujours redemarrer qBittorrent apres Gluetun
docker compose restart gluetun && sleep 10 && docker compose restart qbittorrent
```

**Prevention** : Ne jamais redemarrer Gluetun seul. Un `docker compose up -d` global est safe car il respecte l'ordre `depends_on`.

---

## 9. qBittorrent — Config revient aux anciens chemins (/downloads au lieu de /data/downloads)

**Date** : 2026-03-06

**Symptome** : Apres chaque redemarrage, qBittorrent utilise `/downloads/complete` au lieu de `/data/downloads/complete`. Les torrents finis echouent avec "mkdir (): Permission denied" car `/downloads/complete` n'existe pas dans le conteneur.

**Cause** : qBittorrent detecte un "unclean program exit" a chaque arret Docker et restaure depuis un fichier fallback `qBittorrent_new.conf` qui contient les anciens chemins. Ce fichier est dans le sous-dossier `config/qbittorrent/qBittorrent/`.

**Diagnostic** :
```bash
# Voir le fallback dans les logs
docker compose logs qbittorrent 2>&1 | grep "unclean\|fallback"

# Lister et verifier tous les fichiers config
find config/qbittorrent -name "*.conf" -exec grep -n "SavePath\|TempPath" {} \;
```

**Solution** :
```bash
# Arreter, corriger TOUS les fichiers, redemarrer
docker compose stop gluetun
find config/qbittorrent -name "*.conf" -exec grep -l "downloads" {} \; | while read f; do
  sed -i 's|=/downloads/|=/data/downloads/|g' "$f"
done
docker compose up -d gluetun && sleep 10 && docker compose restart qbittorrent
```

**Prevention** : Le fichier `qBittorrent.conf` dans le repo Git contient desormais les bons chemins `/data/downloads/`. Apres un `git pull`, copier aussi vers le sous-dossier runtime.

---

## Reseau — Rappel des IPs

> **Note** : Ces IPs sont specifiques a l'environnement de deploiement actuel. Adaptez-les a votre configuration.

| Ressource | IP | Port |
|---|---|---|
| VM Freebox (SFTP) | 192.168.1.250 | 2222 |
| Routeur Freebox (WireGuard) | 192.168.27.64 | 22563 |
| Gateway Docker `vps_media_network` | 172.20.0.1 | — |
| Gateway Docker `bridge` (docker0) | 172.17.0.1 | — |
| FlareSolverr (PM2, pour autres bots) | localhost | 8191 |
| Byparr (Docker, pour Prowlarr) | byparr (reseau Docker) | 8191 (host: 8192) |
