# Migration qBittorrent + Gluetun vers Freebox Ultra

Guide pas-a-pas pour migrer qBittorrent et Gluetun du VPS vers la Freebox Ultra, remplacer rclone/SFTP par un montage CIFS/SMB, et reconfigurer Sonarr/Radarr pour utiliser le nouveau setup.

**Etat avant migration** :
- VPS : gluetun, qbittorrent, rclone (sync vers Freebox via SFTP)
- Freebox : sftp, jellyfin

**Etat apres migration** :
- VPS : sonarr, radarr, prowlarr, seerr, nginx, homepage, etc. (+ montage CIFS)
- Freebox : gluetun, qbittorrent, jellyfin
- rclone et sftp supprimes (plus de transit de fichiers)

---

## Prerequis

- [ ] Tunnel WireGuard VPS-Freebox operationnel (AllowedIPs inclut 192.168.1.0/24)
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

**1b.** Deployer les nouveaux services :

```bash
cd freebox && docker compose up -d gluetun qbittorrent
```

**1c.** Verifier que gluetun est healthy :

```bash
docker inspect --format='{{.State.Health.Status}}' gluetun
```

**1d.** Verifier l'IP VPN (doit etre Mullvad, pas la Freebox) :

```bash
docker exec gluetun wget -qO- https://ipinfo.io/json
```

**1e.** Verifier que qBittorrent est accessible depuis le VPS (via WireGuard) :

```bash
# Depuis le VPS
curl http://${FREEBOX_WG_IP}:8080
```

---

## Etape 2 — Monter CIFS sur le VPS

Le NVMe Freebox est partage via SMB par le routeur (192.168.1.254). Le VPS monte ce partage via CIFS over WireGuard.

**2a.** Installer le client CIFS :

```bash
apt-get install -y cifs-utils
```

**2b.** Creer le fichier de credentials :

```bash
cat > /etc/cifs-credentials << EOF
username=freebox
password=MOT_DE_PASSE_SMB
EOF
chmod 600 /etc/cifs-credentials
```

**2c.** Ajouter l'entree fstab :

```bash
mkdir -p /mnt/freebox
echo '//192.168.1.254/NVMe /mnt/freebox cifs credentials=/etc/cifs-credentials,uid=1000,gid=1000,vers=3.0,_netdev,x-systemd.automount,x-systemd.after=wg-quick@wg-freebox.service 0 0' >> /etc/fstab
systemctl daemon-reload
mount /mnt/freebox
```

**2d.** Verifier le montage :

```bash
df -h /mnt/freebox
ls /mnt/freebox/Vidéos/
```

---

## Etape 3 — Reconfigurer Sonarr et Radarr

**3a.** Dans les WebUI Sonarr et Radarr → Settings → Download Clients :

- **Host** : `${FREEBOX_WG_IP}` (ex: `192.168.1.250`)
- **Port** : `8080`
- **Password** : le `QBIT_PASSWORD` du `.env` Freebox

**3b.** Root Folders :

- Radarr : `/data/Vidéos/3 - FILMS` (ou `/data/Vidéos` si tout au meme endroit)
- Sonarr : `/data/Vidéos/2 - SERIES` (ou `/data/Vidéos` si tout au meme endroit)

**3c.** Mettre a jour Seerr — Settings → Sonarr/Radarr : changer le root folder pour correspondre.

**3d.** Tester un telechargement end-to-end.

---

## Etape 4 — Mettre a jour le VPS docker-compose

**4a.** `vps/docker-compose.yml` : supprimer gluetun, qbittorrent, rclone. Sonarr/Radarr volumes → `/mnt/freebox:/data`.

**4b.** Appliquer :

```bash
docker compose up -d --remove-orphans
```

---

## Etape 5 — Mettre a jour nginx

```bash
sed -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
    -e "s|FREEBOX_WG_IP_PLACEHOLDER|${FREEBOX_WG_IP}|g" \
    nginx/media-stack.conf.template > /etc/nginx/sites-available/media-stack

nginx -t && systemctl reload nginx
```

---

## Etape 6 — Nettoyage VPS

Supprimer les anciennes donnees (**APRES** avoir verifie que tout fonctionne) :

```bash
rm -rf ${DATA_PATH}/downloads/
rm -rf ${DATA_PATH}/media/
```

Supprimer `DATA_PATH` du `.env` VPS.

---

## Rollback

- Reactiver l'ancien download client qBittorrent (VPS) dans Sonarr/Radarr
- `git checkout vps/docker-compose.yml && docker compose up -d`

---

## Verification finale

- [ ] qBittorrent sur Freebox est healthy et accessible via `https://qbittorrent.DOMAIN`
- [ ] L'IP VPN est bien Mullvad (`docker exec gluetun wget -qO- https://ipinfo.io/json`)
- [ ] CIFS mount `/mnt/freebox` est actif sur le VPS (`df -h /mnt/freebox`)
- [ ] Sonarr/Radarr utilisent le download client Freebox
- [ ] Un telechargement test fonctionne de bout en bout
- [ ] Les hardlinks fonctionnent (`ls -li` pour verifier les inodes)
- [ ] Homepage widget qBittorrent affiche les stats
