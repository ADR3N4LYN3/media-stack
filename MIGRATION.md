# Migration qBittorrent + Gluetun vers Freebox Ultra

Guide pas-a-pas pour migrer qBittorrent et Gluetun du VPS vers la Freebox Ultra, remplacer rclone/SFTP par un montage NFS, et reconfigurer Sonarr/Radarr pour utiliser le nouveau setup.

**Etat avant migration** :
- VPS : gluetun, qbittorrent, rclone (sync vers Freebox via SFTP)
- Freebox : sftp, jellyfin

**Etat apres migration** :
- VPS : sonarr, radarr, prowlarr, seerr, nginx, homepage, etc. (+ montage NFS)
- Freebox : gluetun, qbittorrent, jellyfin, sftp, serveur NFS natif
- rclone supprime du VPS (plus de transit de fichiers)

---

## Prerequis

- [ ] Tunnel WireGuard VPS-Freebox operationnel
- [ ] Freebox `docker-compose.yml` mis a jour (gluetun + qbittorrent ajoutes)
- [ ] Freebox `.env` rempli avec les credentials Mullvad, `QBIT_PASSWORD`, `FREEBOX_WG_IP`

---

## Etape 1 — Preparer la Freebox

**1a.** Copier les credentials Mullvad depuis le `.env` VPS vers le `.env` Freebox :

```bash
# Les variables a copier :
# WIREGUARD_PRIVATE_KEY=...
# WIREGUARD_ADDRESSES=...
```

**1b.** Creer les repertoires necessaires :

```bash
mkdir -p /data/downloads/complete /data/downloads/incomplete /data/media/films /data/media/series
```

**1c.** Deployer les nouveaux services :

```bash
cd freebox && docker compose up -d gluetun qbittorrent
```

**1d.** Verifier que gluetun est healthy :

```bash
docker inspect --format='{{.State.Health.Status}}' gluetun
```

**1e.** Verifier l'IP VPN (doit etre Mullvad, pas la Freebox) :

```bash
docker exec gluetun wget -qO- https://ipinfo.io/json
```

**1f.** Verifier que qBittorrent est accessible depuis le VPS (via WireGuard) :

```bash
# Depuis le VPS
curl http://${FREEBOX_WG_IP}:8080
```

---

## Etape 2 — Installer le serveur NFS sur la Freebox

**2a.** Executer le script d'installation NFS :

```bash
bash nfs-setup.sh <VPS_WG_IP>
# Exemple :
bash nfs-setup.sh 192.168.27.65
```

**2b.** Verifier l'export NFS :

```bash
exportfs -v
```

---

## Etape 3 — Monter NFS sur le VPS

**3a.** Installer le client NFS :

```bash
apt-get install -y nfs-common
```

**3b.** Deployer le unit systemd. Le `setup.sh` a deja ete mis a jour, il suffit de relancer la section NFS. Sinon, manuellement :

```bash
# Copier le fichier unit (remplacer FREEBOX_WG_IP_PLACEHOLDER par la vraie IP)
cp vps/systemd/mnt-freebox.mount /etc/systemd/system/
sed -i "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" /etc/systemd/system/mnt-freebox.mount

# Activer et demarrer le montage
systemctl daemon-reload
systemctl enable --now mnt-freebox.mount
```

**3c.** Verifier le montage :

```bash
df -h /mnt/freebox
ls /mnt/freebox/media/
```

---

## Etape 4 — Reconfigurer Sonarr et Radarr

**4a.** Dans les WebUI Sonarr et Radarr → Settings → Download Clients :

- Ajouter un **nouveau** download client qBittorrent :
  - **Host** : `${FREEBOX_WG_IP}` (la vraie IP, ex: `192.168.27.64`)
  - **Port** : `8080`
  - **Password** : le `QBIT_PASSWORD` du `.env` Freebox
- **Garder l'ancien download client actif** pour le moment

**4b.** Root Folders — les chemins restent identiques grace au montage NFS :

- Films : `/data/media/films` (inchange)
- Series : `/data/media/series` (inchange)

**4c.** Tester un telechargement :

1. Lancer un telechargement manuel depuis Radarr ou Sonarr
2. Verifier que le torrent apparait dans qBittorrent sur la Freebox
3. Verifier que le fichier est visible dans `/mnt/freebox/downloads/complete/` sur le VPS
4. Verifier que Sonarr/Radarr importent correctement le fichier

**4d.** Si tout est OK : desactiver l'ancien download client (VPS) dans Sonarr et Radarr.

---

## Etape 5 — Mettre a jour le VPS docker-compose

**5a.** Attendre que rclone finisse de syncer les fichiers en cours :

```bash
docker logs rclone --tail 10
```

**5b.** Mettre a jour `vps/docker-compose.yml` (la version modifiee supprime gluetun, qbittorrent, rclone et met a jour les volumes Sonarr/Radarr).

**5c.** Appliquer les changements :

```bash
docker compose up -d --remove-orphans
```

**5d.** Verifier que tous les services sont healthy :

```bash
docker compose ps
```

---

## Etape 6 — Mettre a jour nginx

**6a.** Regenerer la config nginx pour le nouveau `proxy_pass` qBittorrent vers la Freebox. Soit relancer la section nginx de `setup.sh`, soit manuellement :

```bash
sed -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
    -e "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
    nginx/media-stack.conf.template > /etc/nginx/sites-available/media-stack

nginx -t && systemctl reload nginx
```

**6b.** Verifier que qBittorrent est accessible via le reverse proxy :

```bash
curl -I https://qbittorrent.${DOMAIN}
# Doit retourner 200
```

---

## Etape 7 — Nettoyage VPS

**7a.** Supprimer les anciennes donnees (**APRES** avoir verifie que tout fonctionne) :

```bash
# Anciens telechargements
rm -rf ${DATA_PATH}/downloads/

# Anciennes copies synchronisees
rm -rf ${DATA_PATH}/media/
```

**7b.** Eventuellement detacher le volume Hetzner si plus necessaire.

---

## Rollback

### Probleme a l'etape 4

- Reactiver l'ancien download client qBittorrent (VPS) dans Sonarr/Radarr
- Aucune donnee perdue — les deux instances peuvent coexister temporairement

### Probleme a l'etape 5

```bash
git checkout vps/docker-compose.yml
docker compose up -d
```

---

## Verification finale

- [ ] qBittorrent sur Freebox est healthy et accessible via `https://qbittorrent.DOMAIN`
- [ ] L'IP VPN est bien Mullvad (`docker exec gluetun wget -qO- https://ipinfo.io/json`)
- [ ] NFS mount `/mnt/freebox` est actif sur le VPS (`df -h /mnt/freebox`)
- [ ] Sonarr/Radarr utilisent le download client Freebox
- [ ] Un telechargement test fonctionne de bout en bout
- [ ] Les hardlinks fonctionnent (`ls -li` pour verifier les inodes)
- [ ] Homepage widget qBittorrent affiche les stats
- [ ] rclone n'est plus en cours d'execution sur le VPS
