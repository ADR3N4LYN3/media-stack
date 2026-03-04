# Media Stack Self-Hosted

Stack media automatisee, securisee et optimisee : telechargement sur VPS derriere VPN Mullvad, sync SFTP vers Freebox Ultra, lecture Plex 4K direct play.

## Architecture

```
VPS Hetzner AX22 (Helsinki)                 Freebox Ultra (domicile)
─────────────────────────────               ────────────────────────
Caddy        ← reverse proxy HTTPS          Plex Media Server
Overseerr    ← demandes utilisateur              ↑
Homarr       ← dashboard monitoring         NVMe interne
Sonarr       ← gestion series               /mnt/NVMe/media/
Radarr       ← gestion films                ├── films/
Prowlarr     ← indexeurs torrent             └── series/
qBittorrent  ← torrent (VPN Gluetun)
rclone       ← sync SFTP ────────────────→
Fail2ban     ← protection brute-force
Watchtower   ← MAJ auto images Docker
```

**Flux :**
1. Demande via Overseerr → Sonarr/Radarr cherchent via Prowlarr
2. qBittorrent telecharge (derriere VPN Mullvad via Gluetun)
3. rclone sync automatique VPS → Freebox NVMe via SFTP
4. Plex detecte et rend disponible → stream 4K direct play

## Prerequis

- **VPS** : Hetzner AX22 (ou similaire) sous Ubuntu 22.04 LTS minimum
- **Freebox Ultra** : Docker active dans Freebox OS, NVMe interne monte
- **VPN** : Compte Mullvad avec cle WireGuard generee
- **Domaine** : DNS A record pointant vers l'IP du VPS
- **Plex** : Compte gratuit (Plex Pass optionnel pour transcodage materiel)

## Deploiement

### Etape 1 — Freebox (en premier)

```bash
cd freebox/
cp .env.example .env
nano .env    # Remplir FREEBOX_IP + PLEX_CLAIM (https://plex.tv/claim, 4 min)

bash scripts/setup-freebox.sh
# → Noter l'IP locale de la Freebox
# → Configurer SSH et coller la cle publique du VPS
```

### Etape 2 — VPS

```bash
cd vps/
cp .env.example .env
nano .env    # Remplir : WireGuard keys, Freebox SSH, domaine, Caddy auth

# Generer le hash du mot de passe Caddy :
docker run --rm caddy caddy hash-password

bash scripts/setup.sh
# → Inclut automatiquement le durcissement systeme (harden.sh)
# → Affiche la cle SSH publique a copier sur la Freebox
# → Attend que les healthchecks soient OK
```

### Etape 3 — Configuration post-demarrage

Dans cet ordre :

1. **Prowlarr** (`https://prowlarr.DOMAIN`)
   - Ajouter les indexeurs : Cpasbien, OxTorrent, 1337x, RuTracker (voir tableau ci-dessous)
   - Sharewood en priorite 1 si invitation disponible

2. **Radarr** (`https://radarr.DOMAIN`)
   - Settings → Indexers → connecter Prowlarr
   - Settings → Download Clients → ajouter qBittorrent (host: `gluetun`, port: `8080`)
   - Settings → Profiles → creer profil "4K FR" :
     - 2160p Remux > Bluray-2160p > WEB-2160p
     - Audio FR prioritaire, EN en fallback

3. **Sonarr** (`https://sonarr.DOMAIN`)
   - Meme configuration que Radarr

4. **Overseerr** (`https://overseerr.DOMAIN`)
   - Connecter Plex (serveur Freebox)
   - Connecter Sonarr + Radarr

5. **Homarr** (`https://home.DOMAIN`)
   - Configurer les widgets avec les API keys des services

6. **Plex** (`http://FREEBOX_IP:32400/web`)
   - Ajouter bibliotheque Films → `/data/films`
   - Ajouter bibliotheque Series → `/data/series`
   - Reglages recommandes :
     - Transcoder quality → "Make my CPU hurt"
     - Background transcoding → `veryfast`
     - Generate video preview thumbnails → Desactive
     - Generate chapter image thumbnails → Desactive

### Indexeurs recommandes (Prowlarr)

| Indexeur | Type | Priorite | Notes |
|---|---|---|---|
| Cpasbien | Public | 1 | Principal tracker FR, catalogue VF/VOSTFR |
| OxTorrent | Public | 2 | Bon catalogue FR, sans inscription |
| 1337x | Public | 3 | Tres bon pour contenu international 4K |
| RuTracker | Semi-prive | 4 | Reference pour remux et raretes, inscription gratuite |
| Sharewood | Prive | 5 | A ajouter si invitation obtenue — meilleure qualite FR |

### Etape 4 — Test de validation end-to-end

1. Ouvrir Overseerr et demander un film recent disponible en 4K
2. Verifier dans Radarr que la recherche s'est lancee
3. Verifier dans qBittorrent que le telechargement est actif
4. Verifier que l'IP affichee est bien Mullvad (pas la vraie IP du VPS)
5. Attendre la fin → verifier que le fichier apparait dans Plex

## Structure du projet

```
media-stack/
├── README.md
├── .gitignore
├── vps/
│   ├── docker-compose.yml       # 11 services
│   ├── .env.example             # Variables a personnaliser
│   ├── Caddyfile                # Reverse proxy HTTPS + security headers
│   ├── fail2ban/
│   │   ├── jail.local           # Jails SSH + Caddy auth
│   │   └── filter.d/
│   │       └── caddy-auth.conf  # Filtre BasicAuth echoue
│   ├── config/
│   │   ├── rclone/
│   │   │   └── rclone.conf.template
│   │   └── qbittorrent/
│   │       └── qBittorrent.conf # Config optimisee
│   └── scripts/
│       ├── setup.sh             # Installation VPS
│       ├── harden.sh            # Durcissement systeme
│       └── sync-watch.sh        # Sync temps reel (inotify)
└── freebox/
    ├── docker-compose.yml       # Plex Media Server
    ├── .env.example
    └── scripts/
        └── setup-freebox.sh     # Installation Freebox
```

## Variables a personnaliser

| Variable | Fichier | Description |
|---|---|---|
| `WIREGUARD_PRIVATE_KEY` | `vps/.env` | Cle privee WireGuard Mullvad |
| `WIREGUARD_ADDRESSES` | `vps/.env` | Adresse IP WireGuard |
| `FREEBOX_HOST` | `vps/.env` | IP publique ou hostname de la Freebox |
| `FREEBOX_USER` | `vps/.env` | Utilisateur SSH Freebox |
| `DOMAIN` | `vps/.env` | Domaine pointant vers le VPS |
| `CADDY_USER` | `vps/.env` | Utilisateur basic auth Caddy |
| `CADDY_PASSWORD_HASH` | `vps/.env` | Hash genere via `docker run --rm caddy caddy hash-password` |
| `SSH_PORT` | `vps/.env` | Port SSH custom (defaut: 2222) |
| `PLEX_CLAIM` | `freebox/.env` | Token https://plex.tv/claim (expire en 4 min) |
| `FREEBOX_IP` | `freebox/.env` | IP locale de la Freebox |

## Securite

- **VPN obligatoire** : qBittorrent ne demarre jamais sans VPN actif (healthcheck Gluetun)
- **Aucun port interne expose** : seuls Caddy (80/443) et qBittorrent via Gluetun sont accessibles
- **no-new-privileges** sur tous les conteneurs sauf Gluetun
- **Security headers** HSTS, X-Content-Type-Options, X-Frame-Options sur tous les services
- **BasicAuth** Caddy sur tous les services internes (Sonarr, Radarr, Prowlarr, Homarr, qBittorrent)
- **Fail2ban** actif sur SSH (ban 24h apres 3 echecs) et BasicAuth Caddy (ban 1h apres 5 echecs)
- **SSH durci** : port custom, password auth desactive, root login desactive
- **Plex en lecture seule** : volumes media montes en `:ro`
- **Donnees sensibles** : tout dans `.env`, jamais en dur dans les fichiers versionnes
- **Mises a jour auto** : unattended-upgrades pour la securite systeme + Watchtower pour Docker
- **Docker hardened** : logs limites, userland-proxy desactive, no-new-privileges global

## Commandes utiles

```bash
# Verifier que qBittorrent tourne bien derriere le VPN
docker exec gluetun wget -qO- https://ipinfo.io/json

# Voir les logs de sync rclone
tail -f /var/log/rclone-sync.log

# Logs d'un service specifique
docker logs -f sonarr

# Renouveler les images et redemarrer
docker compose pull && docker compose up -d

# Status des services
docker compose ps

# Verifier les bans fail2ban
docker exec fail2ban fail2ban-client status
docker exec fail2ban fail2ban-client status caddy-auth
```

## Sync avancee (optionnel)

Le script `sync-watch.sh` offre une sync en temps reel en complement du conteneur rclone :

```bash
# Sur le VPS
nohup bash scripts/sync-watch.sh &
```

- Detection instantanee via inotify (pas d'attente 5 min)
- Verification de stabilite du fichier (30s)
- Retry automatique avec backoff exponentiel (10s, 30s, 90s)
- Notifications webhook Discord/Slack
- Fallback sync complete toutes les heures
