# Media Stack Self-Hosted

Stack media automatisee, securisee et optimisee : telechargement sur VPS derriere VPN Mullvad, sync via tunnel WireGuard vers Freebox Ultra, lecture 4K direct play via le player Freebox.

## Architecture

```
VPS Hetzner AX22 (Helsinki)                 Freebox Ultra (domicile)
─────────────────────────────               ────────────────────────
nginx        ← reverse proxy HTTPS          Player Freebox (lecture 4K)
               (Cloudflare SSL)             SFTP (conteneur Docker)
Authelia      ← SSO (portail auth unique)        ↑
Overseerr    ← demandes utilisateur         NVMe interne
Homepage     ← dashboard monitoring         /mnt/NVMe/media/
Sonarr       ← gestion series              ├── films/
Radarr       ← gestion films               └── series/
Prowlarr     ← indexeurs torrent
qBittorrent  ← torrent (VPN Gluetun)
rclone       ← sync SFTP ──── WireGuard tunnel ────→
Fail2ban     ← protection brute-force
Watchtower   ← MAJ auto images Docker       WireGuard Server (natif Freebox)
WireGuard    ← tunnel vers Freebox (host)
```

**Flux :**
1. Demande via Overseerr → Sonarr/Radarr cherchent via Prowlarr
2. qBittorrent telecharge (derriere VPN Mullvad via Gluetun)
3. rclone sync automatique VPS → Freebox NVMe via SFTP sur tunnel WireGuard
4. Player Freebox lit directement depuis le NVMe → 4K direct play

## Prerequis

- **VPS** : Hetzner AX22 (ou similaire) sous Ubuntu 22.04 LTS minimum, nginx installe
- **Freebox Ultra** : Docker active dans Freebox OS, NVMe interne monte
- **VPN Mullvad** : Compte avec cle WireGuard generee (pour les torrents)
- **WireGuard Freebox** : Serveur VPN active dans Freebox OS → Parametres → Serveur VPN → WireGuard
- **Domaine** : DNS via Cloudflare, A records pointant vers l'IP du VPS (proxy ON)
- **Cloudflare SSL** : Certificats origin generes et places dans `/etc/ssl/cloudflare/`


## Documentation

| Document | Description |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture technique detaillee (services, reseau, securite) |
| [docs/GUIDE.md](docs/GUIDE.md) | Guide d'installation pas-a-pas |
| [docs/OPS.md](docs/OPS.md) | Operations, maintenance, sauvegardes et procedures d'urgence |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Journal des bugs rencontres et solutions |

## Deploiement

### Etape 0 — Configurer WireGuard sur la Freebox

1. Freebox OS → **Parametres** → **Mode avance** → **Connexion Internet** → **Serveur VPN**
2. Cliquer sur **WireGuard** → **Activer** → **Appliquer**
3. Aller dans **Utilisateurs** → **Ajouter** :
   - Login : `mediastack` (ou autre)
   - Type : WireGuard
   - IP Fixe : laisser celle proposee
   - Keepalive : 25
4. **Telecharger le fichier .conf** → noter les valeurs pour le `.env` du VPS

### Etape 1 — Freebox (SFTP)

```bash
cd freebox/
cp .env.example .env
nano .env    # Remplir les variables

bash scripts/setup-freebox.sh
# → Coller la cle publique SSH du VPS quand demande
# → Lance le conteneur SFTP
```

### Etape 2 — VPS

```bash
cd vps/
cp .env.example .env
nano .env    # Remplir : Mullvad WireGuard, tunnel Freebox, domaine, Authelia secrets

bash scripts/setup.sh
# → Installe WireGuard et monte le tunnel vers la Freebox
# → Genere la cle SSH pour rclone
# → Configure Authelia SSO (hash Argon2id, users_database.yml)
# → Configure nginx reverse proxy avec auth_request Authelia
# → Inclut automatiquement le durcissement systeme (harden.sh)
# → Attend que les healthchecks soient OK
```

### Etape 2b — DNS Cloudflare

Creer les A records suivants (tous pointant vers l'IP du VPS, proxy ON) :

| Sous-domaine | Service |
|---|---|
| `auth.DOMAIN` | Authelia (portail SSO) |
| `overseerr.DOMAIN` | Overseerr |
| `sonarr.DOMAIN` | Sonarr |
| `radarr.DOMAIN` | Radarr |
| `prowlarr.DOMAIN` | Prowlarr |
| `qbittorrent.DOMAIN` | qBittorrent |
| `home.DOMAIN` | Homepage |
| `logs.DOMAIN` | Dozzle |
| `jackett.DOMAIN` | Jackett |

### Etape 3 — Configuration post-demarrage

Dans cet ordre :

1. **Authelia** (`https://auth.DOMAIN`)
   - Se connecter avec les identifiants definis dans `.env`
   - Configurer le TOTP (2FA) pour les services admin

2. **Prowlarr** (`https://prowlarr.DOMAIN`)
   - Ajouter les indexeurs : Cpasbien, OxTorrent, 1337x, RuTracker (voir tableau ci-dessous)
   - Sharewood en priorite 1 si invitation disponible

3. **Radarr** (`https://radarr.DOMAIN`)
   - Settings → Indexers → connecter Prowlarr
   - Settings → Download Clients → ajouter qBittorrent (host: `gluetun`, port: `8080`)
   - Settings → Profiles → creer profil "4K FR" :
     - 2160p Remux > Bluray-2160p > WEB-2160p
     - Audio FR prioritaire, EN en fallback

4. **Sonarr** (`https://sonarr.DOMAIN`)
   - Meme configuration que Radarr

5. **Overseerr** (`https://overseerr.DOMAIN`)
   - Connecter Sonarr + Radarr
   - Configurer l'authentification interne (pas de SSO Authelia — acces simplifie pour amis/famille)

6. **Homepage** (`https://home.DOMAIN`)
   - Deja preconfigure via les fichiers YAML dans `config/homepage/`
   - Les cles API sont passees en variables d'environnement

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
5. Attendre la fin → verifier que le fichier apparait sur le NVMe Freebox

## Structure du projet

```
media-stack/
├── README.md
├── .gitignore
├── docs/
│   ├── ARCHITECTURE.md          # Architecture technique detaillee
│   ├── GUIDE.md                 # Guide d'installation pas-a-pas
│   ├── OPS.md                   # Operations, maintenance, sauvegardes
│   └── TROUBLESHOOTING.md       # Journal des bugs et solutions
├── vps/
│   ├── docker-compose.yml       # 14 services (sans nginx, sur le host)
│   ├── .env.example             # Variables a personnaliser
│   ├── nginx/
│   │   ├── media-stack.conf.template  # Template reverse proxy
│   │   └── snippets/
│   │       ├── authelia-location.conf      # Endpoint interne Authelia
│   │       └── authelia-authrequest.conf   # auth_request + redirect
│   ├── fail2ban/
│   │   ├── jail.local           # Jails SSH + nginx auth
│   │   └── filter.d/
│   │       └── nginx-auth.conf  # Filtre auth echoue
│   ├── config/
│   │   ├── authelia/
│   │   │   ├── configuration.yml.template  # Template config Authelia SSO
│   │   │   └── users_database.yml          # Template utilisateurs (placeholders)
│   │   ├── rclone/
│   │   │   └── rclone.conf.template
│   │   ├── qbittorrent/
│   │   │   ├── qBittorrent.conf            # Config optimisee
│   │   │   └── custom-services.d/
│   │   │       └── set-password.sh         # Auto-config mot de passe qBit
│   │   └── homepage/
│   │       ├── services.yaml    # Widgets et services du dashboard
│   │       ├── settings.yaml    # Theme, layout, langue
│   │       └── widgets.yaml     # Widgets systeme (CPU, RAM, disque)
│   └── scripts/
│       ├── setup.sh             # Installation VPS + tunnel WireGuard + Authelia + nginx
│       ├── harden.sh            # Durcissement systeme
│       └── sync-watch.sh        # Sync temps reel (inotify)
└── freebox/
    ├── docker-compose.yml       # SFTP
    ├── .env.example
    └── scripts/
        └── setup-freebox.sh     # Installation Freebox
```

## Variables a personnaliser

| Variable | Fichier | Description |
|---|---|---|
| `WIREGUARD_PRIVATE_KEY` | `vps/.env` | Cle privee WireGuard Mullvad (pour torrents) |
| `WIREGUARD_ADDRESSES` | `vps/.env` | Adresse IP WireGuard Mullvad |
| `WG_FREEBOX_PRIVATE_KEY` | `vps/.env` | Cle privee du tunnel VPS→Freebox (fichier .conf telecharge) |
| `WG_FREEBOX_ADDRESS` | `vps/.env` | Adresse IP du VPS dans le tunnel (ex: 192.168.27.65/32) |
| `WG_FREEBOX_PUBLIC_KEY` | `vps/.env` | Cle publique de la Freebox (dans le fichier .conf, section [Peer]) |
| `WG_FREEBOX_ENDPOINT` | `vps/.env` | IP publique de la Freebox (dans le fichier .conf, Endpoint sans le port) |
| `FREEBOX_WG_IP` | `vps/.env` | IP de la machine hebergeant le SFTP Freebox, accessible via le tunnel (IP LAN de la VM si Docker tourne dans une VM, ou IP WireGuard du routeur si Docker est natif) |
| `DOMAIN` | `vps/.env` | Domaine pointant vers le VPS (ex: media.exemple.fr) |
| `HETZNER_VOLUME_PATH` | `vps/.env` | Chemin du volume Hetzner (pour widget disque Homepage) |
| `AUTHELIA_JWT_SECRET` | `vps/.env` | Secret JWT Authelia (min 32 chars, `openssl rand -hex 32`) |
| `AUTHELIA_SESSION_SECRET` | `vps/.env` | Secret session Authelia (min 32 chars) |
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | `vps/.env` | Cle de chiffrement stockage Authelia (min 32 chars) |
| `AUTHELIA_USER` | `vps/.env` | Nom d'utilisateur Authelia |
| `AUTHELIA_PASSWORD` | `vps/.env` | Mot de passe Authelia (hashe en Argon2id par setup.sh) |
| `AUTHELIA_EMAIL` | `vps/.env` | Email de l'utilisateur Authelia |
| `SSH_PORT` | `vps/.env` | Port SSH custom (defaut: 2222) |
| `WG_FREEBOX_IP` | `freebox/.env` | IP WireGuard de la Freebox (pour bind SFTP) |

## Securite

- **VPN obligatoire** : qBittorrent ne demarre jamais sans VPN actif (healthcheck Gluetun)
- **Tunnel WireGuard** : transferts VPS→Freebox chiffres, SFTP accessible uniquement via le tunnel
- **Aucun port interne expose** : seuls nginx (80/443) sont accessibles depuis l'exterieur
- **Cloudflare proxy** : IP reelle du VPS masquee, protection DDoS
- **Authelia SSO** : authentification unique pour les services admin (2FA TOTP). Overseerr utilise son auth interne (plus simple pour les utilisateurs non-techniques)
- **no-new-privileges** sur tous les conteneurs sauf Gluetun
- **Security headers** HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy sur tous les services
- **Fail2ban** actif sur SSH (ban 24h apres 3 echecs) et auth nginx (ban 1h apres 5 echecs)
- **SSH durci** : port custom, password auth desactive, root login desactive
- **Docker socket read-only** : tous les conteneurs avec docker.sock en `:ro`
- **Donnees sensibles** : tout dans `.env`, jamais en dur dans les fichiers versionnes
- **Mises a jour auto** : unattended-upgrades pour la securite systeme + Watchtower pour Docker
- **Docker hardened** : logs limites, userland-proxy desactive, no-new-privileges global

## Commandes utiles

```bash
# Verifier que qBittorrent tourne bien derriere le VPN
docker exec gluetun wget -qO- https://ipinfo.io/json

# Verifier le tunnel WireGuard vers la Freebox
wg show wg-freebox
ping -c 3 FREEBOX_WG_IP

# Voir les logs de sync rclone
docker logs -f rclone

# Logs d'un service specifique
docker logs -f sonarr

# Renouveler les images et redemarrer
docker compose pull && docker compose up -d

# Status des services
docker compose ps

# Verifier les bans fail2ban
docker exec fail2ban fail2ban-client status
docker exec fail2ban fail2ban-client status nginx-auth

# Tester la config nginx
nginx -t && systemctl reload nginx
```

## Sync avancee (optionnel)

Le script `sync-watch.sh` offre une sync en temps reel en complement du conteneur rclone :

```bash
# Sur le VPS
nohup bash scripts/sync-watch.sh &
```

- Detection instantanee via inotify (pas d'attente 1 min)
- Verification de stabilite du fichier (30s)
- Retry automatique avec backoff exponentiel (10s, 30s, 90s)
- Notifications webhook Discord/Slack
- Fallback sync complete toutes les heures
