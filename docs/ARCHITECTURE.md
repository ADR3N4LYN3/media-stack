# Architecture technique — Media Stack

Documentation detaillee de l'architecture du projet media-stack : infrastructure Docker self-hosted repartie entre un VPS et une Freebox Ultra.

---

## Table des matieres

1. [Vue d'ensemble](#vue-densemble)
2. [Services Docker VPS](#services-docker-vps)
3. [Services Docker Freebox](#services-docker-freebox)
4. [Reseau](#reseau)
5. [Flux de donnees](#flux-de-donnees)
6. [Securite](#securite)

---

## Vue d'ensemble

L'architecture repose sur deux noeuds physiques relies par un tunnel WireGuard chiffre :

- **VPS Hetzner AX22** (Helsinki) : telechargement automatise derriere VPN Mullvad, gestion des medias, reverse proxy HTTPS. Stockage sur Hetzner Volume monte a `DATA_PATH` (contient `downloads/` et `media/` sur le meme filesystem pour les hardlinks)
- **Freebox Ultra** (domicile) : stockage NVMe interne, lecture 4K via le player Freebox integre

```
                         Internet
                            |
                      [Cloudflare CDN]
                       proxy + SSL +
                       protection DDoS
                            |
    ========================|=================================
    |            VPS Hetzner AX22 (Helsinki)                 |
    |                       |                                |
    |              [nginx reverse proxy]                     |
    |                       |                                |
    |              [authelia SSO] ← auth_request             |
    |             /    |    |    |    \                       |
    |            /     |    |    |     \                      |
    |     overseerr sonarr radarr prowlarr homepage           |
    |         |        |    |       |    dozzle              |
    |         |        |    |       |    byparr               |
    |         |        |    |       |    jackett              |
    |         +--------+----+-------+                        |
    |                  |                                     |
    |           [qbittorrent]                                |
    |                  |                                     |
    |             [gluetun] -----> VPN Mullvad (Finlande)    |
    |                                                        |
    |     [rclone] ---- SFTP ---------+                      |
    |                                 |                      |
    |     [fail2ban]  [watchtower]    | tunnel WireGuard     |
    |                                 | (wg-freebox:22563)   |
    =========================|========|======================
                             |        |
    =========================|========|======================
    |       Freebox Ultra (domicile)  |                      |
    |                                 |                      |
    |                          [sftp] <--- port 2222         |
    |                            |                           |
    |                     NVMe interne                       |
                    /data/media/                         |
    |                   +-- films/                            |
    |                   +-- series/                           |
    |                            |                           |
    |              [player freebox] ← lecture 4K direct play |
    ==========================================================
```

### Roles des composants

| Composant | Emplacement | Role |
|---|---|---|
| nginx | VPS (host) | Reverse proxy HTTPS, terminaison SSL Cloudflare |
| Authelia | VPS | SSO — portail d'authentification unique (one_factor/two_factor) |
| Overseerr | VPS | Interface de demande utilisateur (films/series) |
| Sonarr | VPS | Gestion automatisee des series TV |
| Radarr | VPS | Gestion automatisee des films |
| Prowlarr | VPS | Agregateur d'indexeurs torrent |
| qBittorrent | VPS | Client torrent derriere VPN |
| Gluetun | VPS | Tunnel VPN Mullvad WireGuard pour qBittorrent |
| rclone | VPS | Synchronisation SFTP VPS vers Freebox |
| Fail2ban | VPS | Protection brute-force SSH et auth nginx |
| Homepage | VPS | Dashboard de monitoring centralise (widgets YAML) |
| Dozzle | VPS | Visualiseur de logs Docker web |
| Byparr | VPS | Bypass Cloudflare pour Prowlarr (remplace FlareSolverr) |
| Jackett | VPS | Indexeur torrent supplementaire |
| Watchtower | VPS | Mise a jour automatique des images Docker |
| SFTP | Freebox | Reception des fichiers depuis le VPS |

---

## Services Docker VPS

Le VPS execute 14 conteneurs Docker definis dans `vps/docker-compose.yml`. Tous partagent le reseau `media_network` (sauf exceptions notees).

### 1. Gluetun

Passerelle VPN obligatoire pour tout le trafic torrent.

| Propriete | Valeur |
|---|---|
| Image | `qmcgaw/gluetun:latest` |
| Ports | `127.0.0.1:${PORT_QBITTORRENT}:8080` (WebUI qBittorrent) |
| Reseau | `media_network` |
| Capabilities | `NET_ADMIN`, `NET_RAW` |
| Devices | `/dev/net/tun` |
| Volumes | `./config/gluetun:/gluetun`, tmpfs `/tmp/gluetun` |
| Healthcheck | `wget -qO- http://ipinfo.io/ip` (30s interval, 60s start) |

**Configuration VPN :**
- Fournisseur : Mullvad
- Protocole : WireGuard
- Serveurs : Finlande
- DNS : 1.1.1.1 (Cloudflare)
- Subnets autorises : `172.16.0.0/12` (reseau Docker interne)
- Blocage malware : actif

### 2. qBittorrent

Client torrent, isole derriere le VPN Gluetun.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/qbittorrent:latest` |
| Ports | Aucun (passe via Gluetun) |
| Reseau | `network_mode: service:gluetun` |
| Dependance | `gluetun` (condition: `service_healthy`) |
| Volumes | `./config/qbittorrent:/config`, `${DATA_PATH}:/data` |
| Security | `no-new-privileges:true` |

**Configuration qBittorrent** (`vps/config/qbittorrent/qBittorrent.conf`) :
- Telechargements complets : `/downloads/complete`
- Telechargements en cours : `/downloads/incomplete`
- Upload limite : 5120 Ko/s
- Chiffrement : force (policy=1)
- Mode anonyme : actif
- 500 connexions max globales, 100 par torrent

### 3. Prowlarr

Agregateur centralise d'indexeurs torrent.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/prowlarr:latest` |
| Ports | `127.0.0.1:9696:9696` |
| Reseau | `media_network` |
| Volumes | `./config/prowlarr:/config` |
| Healthcheck | `curl -f http://localhost:9696/ping` (30s interval, 60s start) |
| Security | `no-new-privileges:true` |

Prowlarr alimente automatiquement Sonarr et Radarr en indexeurs.

### 4. Sonarr

Gestion automatisee des series TV.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/sonarr:latest` |
| Ports | `127.0.0.1:8989:8989` |
| Reseau | `media_network` |
| Volumes | `./config/sonarr:/config`, `${DATA_PATH}:/data` |
| Dependance | `prowlarr` (condition: `service_healthy`) |
| Security | `no-new-privileges:true` |

### 5. Radarr

Gestion automatisee des films.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/radarr:latest` |
| Ports | `127.0.0.1:7878:7878` |
| Reseau | `media_network` |
| Volumes | `./config/radarr:/config`, `${DATA_PATH}:/data` |
| Dependance | `prowlarr` (condition: `service_healthy`) |
| Security | `no-new-privileges:true` |

### 6. Overseerr

Interface utilisateur pour les demandes de films et series.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/overseerr:latest` |
| Ports | `127.0.0.1:5055:5055` |
| Reseau | `media_network` |
| Volumes | `./config/overseerr:/app/config` |
| Security | `no-new-privileges:true` |

Overseerr est protege par Authelia en one_factor (accessible aux amis/famille sans 2FA).

### 7. Homepage

Dashboard de monitoring centralise avec widgets YAML.

| Propriete | Valeur |
|---|---|
| Image | `ghcr.io/gethomepage/homepage:latest` |
| Ports | `127.0.0.1:7575:3000` |
| Reseau | `media_network` |
| Volumes | `./config/homepage:/app/config`, `/var/run/docker.sock:/var/run/docker.sock:ro` |
| Security | `no-new-privileges:true` |

Widgets configures : search (Overseerr), resources (CPU/RAM/disk systeme + volume Hetzner), datetime.

### 8. Authelia

Portail d'authentification unique (SSO) pour tous les services.

| Propriete | Valeur |
|---|---|
| Image | `authelia/authelia:latest` |
| Ports | `127.0.0.1:9091:9091` |
| Reseau | `media_network` |
| Volumes | `./config/authelia:/config` |
| Healthcheck | `wget -qO- http://localhost:9091/api/health` (30s interval) |
| Security | `no-new-privileges:true` |

**Politique d'acces :**
- Overseerr : `one_factor` (login simple, pour amis/famille)
- Services admin (Sonarr, Radarr, Prowlarr, qBittorrent, Homepage, Dozzle, Jackett) : `two_factor` (TOTP obligatoire)
- Endpoints API Sonarr/Radarr (`/api`) : exclus de l'auth (communication inter-services via API key)

**Configuration :**
- Backend : fichier YAML local (`users_database.yml`)
- Hash : Argon2id (genere par `setup.sh`)
- Session : 12h expiration, 2h inactivite, 1 mois remember_me
- Stockage : SQLite local
- 2FA : TOTP (30s, 6 digits)

### 9. rclone

Synchronisation automatique des medias du VPS vers la Freebox via SFTP sur tunnel WireGuard.

| Propriete | Valeur |
|---|---|
| Image | `rclone/rclone:latest` |
| Ports | Aucun |
| Reseau | `network_mode: host` |
| Entrypoint | `/bin/sh -c` (boucle infinie) |
| Volumes | `${DATA_PATH}/media:/source`, `./config/rclone:/config/rclone:ro`, `./config/rclone/id_rsa:/root/.ssh/id_rsa:ro` |
| Dependances | `sonarr`, `radarr` |
| Security | `no-new-privileges:true` |

**Fonctionnement :**
- Boucle toutes les 1 minute (60 secondes)
- Commande : `rclone move` (deux commandes separees pour films et series)
- Parametres : 2 transferts, 8 checkers, buffer 64M, `--delete-empty-src-dirs`
- Exclusions : `*.part`, `*.!qB` (fichiers en cours de telechargement)
- Authentification : cle SSH privee montee en lecture seule

**Configuration rclone** (`vps/config/rclone/rclone.conf.template`) :
- Remote `freebox` de type SFTP
- Connexion via IP WireGuard de la Freebox, port 2222
- Authentification par cle SSH

### 10. Fail2ban

Protection contre les attaques brute-force.

| Propriete | Valeur |
|---|---|
| Image | `crazymax/fail2ban:latest` |
| Reseau | `network_mode: host` |
| Capabilities | `NET_ADMIN`, `NET_RAW` |
| Volumes | `/var/log:/var/log:ro`, `./fail2ban/jail.local:/etc/fail2ban/jail.local:ro`, `./fail2ban/filter.d:/etc/fail2ban/filter.d:ro`, `fail2ban_data:/var/lib/fail2ban` |

**Jails configurees** (`vps/fail2ban/jail.local`) :

| Jail | Port | Log | Max retries | Ban time |
|---|---|---|---|---|
| `sshd` | 2222 | `/var/log/auth.log` | 3 | 24h |
| `nginx-auth` | HTTP/HTTPS | `/var/log/nginx/error.log` | 5 | 1h |

**Filtre nginx-auth** (`vps/fail2ban/filter.d/nginx-auth.conf`) — detecte les echecs d'authentification nginx.

### 11. Watchtower

Mise a jour automatique des images Docker.

| Propriete | Valeur |
|---|---|
| Image | `containrrr/watchtower:latest` |
| Reseau | `media_network` |
| Volumes | `/var/run/docker.sock:/var/run/docker.sock:ro` |
| Security | `no-new-privileges:true` |

**Configuration :**
- Planification : tous les jours a 3h00 (`0 0 3 * * *`)
- Nettoyage des anciennes images : actif
- Conteneurs arretes ignores
- Notifications Discord via Shoutrrr (`discord://${DISCORD_WATCHTOWER_WEBHOOK_TOKEN}@${DISCORD_WATCHTOWER_WEBHOOK_ID}`) dans le salon #systeme

### 12. Dozzle

Visualiseur de logs Docker en temps reel via interface web.

| Propriete | Valeur |
|---|---|
| Image | `amir20/dozzle:latest` |
| Ports | `127.0.0.1:9999:8080` |
| Reseau | `media_network` |
| Volumes | `/var/run/docker.sock:/var/run/docker.sock:ro` |

### 13. Notifications Discord

Les notifications Discord sont gerees directement par les services via leurs connexions natives (pas de service intermediaire).

| Salon Discord | Source | Evenements |
|---|---|---|
| `#films` | Radarr (webhook Discord natif) | Grab, Import, Upgrade, Manual Interaction |
| `#series` | Sonarr (webhook Discord natif) | Grab, Import, Upgrade, Manual Interaction |
| `#systeme` | Sonarr Health + Radarr Health + Watchtower | Health issues, mises a jour containers |

**Fonctionnement :**
- Sonarr et Radarr envoient les notifications directement via leurs connexions Discord natives (webhook par salon)
- Chaque service a deux connexions : une pour les medias (Grab/Import) et une pour la sante (Health → #systeme)
- Watchtower envoie ses notifications via Shoutrrr (webhook Discord dans `#systeme`)
- Overseerr : notifications Discord desactivees (redondantes avec les Grab)

### 14. Byparr

Bypass Cloudflare pour les indexeurs Prowlarr (remplace FlareSolverr).

| Propriete | Valeur |
|---|---|
| Image | `ghcr.io/thephaseless/byparr:latest` |
| Ports | `127.0.0.1:8192:8191` |
| Reseau | `media_network` |

Utilise par Prowlarr comme proxy pour les indexeurs proteges par Cloudflare.

### 15. Jackett

Indexeur torrent supplementaire.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/jackett:latest` |
| Ports | `127.0.0.1:9117:9117` |
| Reseau | `media_network` |
| Security | `no-new-privileges:true` |

---

## Services Docker Freebox

La Freebox Ultra execute 1 conteneur dans une VM Docker, defini dans `freebox/docker-compose.yml`. La lecture des medias se fait directement via le player Freebox integre (pas de Plex).

### 1. SFTP

Serveur SFTP pour la reception des fichiers depuis le VPS.

| Propriete | Valeur |
|---|---|
| Image | `lscr.io/linuxserver/openssh-server:latest` |
| Ports | `2222:2222` |
| Volumes | `./config/sftp:/config`, `${MEDIA_PATH}:/data` |

**Securite :**
- Acces sudo : desactive
- Authentification par mot de passe : desactivee
- Authentification : cle publique SSH uniquement (`PUBLIC_KEY_FILE`)
- Accessible uniquement via le tunnel WireGuard (pas d'exposition Internet)

---

## Reseau

### Reseau Docker `media_network`

```
Reseau bridge : media_network
Subnet : 172.20.0.0/16
Driver : bridge

Conteneurs connectes :
  +-- gluetun (+ qbittorrent via network_mode: service:gluetun)
  +-- prowlarr
  +-- sonarr
  +-- radarr
  +-- overseerr
  +-- homepage
  +-- authelia
  +-- dozzle
  +-- byparr
  +-- jackett
  +-- watchtower

Conteneurs en mode host :
  +-- rclone (acces au tunnel WireGuard host)
  +-- fail2ban (acces a iptables host)
```

### VPN Mullvad via Gluetun

```
qBittorrent --[network_mode: service:gluetun]--> Gluetun --[WireGuard]--> Mullvad (Finlande)
                                                    |
                                                    +-- /dev/net/tun
                                                    +-- FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/12
                                                    +-- Healthcheck: wget ipinfo.io/ip
```

- qBittorrent n'a pas de stack reseau propre : tout son trafic passe par le conteneur Gluetun
- Si Gluetun tombe ou perd le VPN, qBittorrent perd toute connectivite (kill switch natif)
- Le subnet `172.16.0.0/12` autorise la communication avec les autres conteneurs Docker

### Tunnel WireGuard VPS vers Freebox

```
VPS (host)                                    Freebox Ultra
    |                                              |
[wg-freebox]                              [WireGuard Server natif]
    |                                              |
    +-- IP: ${WG_FREEBOX_ADDRESS}                  +-- IP: ${FREEBOX_WG_IP}
    |   (ex: 192.168.27.65/32)                     |   (ex: 192.168.27.64)
    |                                              |
    +-- Port: ${WG_FREEBOX_PORT} (22563)           +-- Port: 22563
    |                                              |
    +---------- tunnel chiffre WireGuard ----------+
```

- Configure par `setup.sh` au deploiement (interface `wg-freebox` sur le host)
- Utilise par rclone (mode `network_mode: host`) pour atteindre le SFTP Freebox
- Le serveur WireGuard est natif a la Freebox (active dans Freebox OS)

### Nginx reverse proxy

Nginx tourne directement sur le host VPS (pas dans Docker). Il expose 9 sous-domaines via Cloudflare.

```
Internet --> Cloudflare (proxy ON) --> VPS:443 --> nginx --> Authelia (auth_request) --> service local
```

| Sous-domaine | Service | Port local | Authelia |
|---|---|---|---|
| `auth.DOMAIN` | Authelia | 9091 | — (portail lui-meme) |
| `overseerr.DOMAIN` | Overseerr | 5055 | one_factor |
| `sonarr.DOMAIN` | Sonarr | 8989 | two_factor (API exclue) |
| `radarr.DOMAIN` | Radarr | 7878 | two_factor (API exclue) |
| `prowlarr.DOMAIN` | Prowlarr | 9696 | two_factor |
| `qbittorrent.DOMAIN` | qBittorrent | 8080 | two_factor |
| `home.DOMAIN` | Homepage | 7575 | two_factor |
| `logs.DOMAIN` | Dozzle | 9999 | two_factor |
| `jackett.DOMAIN` | Jackett | 9117 | two_factor |

**Configuration** (`vps/nginx/media-stack.conf.template`) :
- Redirection HTTP 80 vers HTTPS 443 sur tous les vhosts
- HTTP/2 active
- Certificats SSL Cloudflare Origin (`/etc/ssl/cloudflare/cert.pem` + `key.pem`)
- Protocoles : TLSv1.2 et TLSv1.3 uniquement
- Ciphers : selection securisee, preference serveur
- Headers de securite : HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- Authelia SSO via `auth_request` directive nginx (snippets inclus dans chaque vhost)
- Proxy headers : X-Real-IP, X-Forwarded-For, X-Forwarded-Proto
- WebSocket support sur Overseerr et Homepage (Upgrade + Connection headers)
- Endpoints `/api` de Sonarr et Radarr exclus de l'authentification Authelia (API key interne)

### Fail2ban

```
/var/log/auth.log    --> [jail sshd]       --> iptables ban 24h (3 echecs)
/var/log/nginx/error.log --> [jail nginx-auth] --> iptables ban 1h (5 echecs)
```

---

## Flux de donnees

Le parcours complet d'un media, de la demande a la lecture :

```
[1] DEMANDE          [2] RECHERCHE         [3] TELECHARGEMENT
Utilisateur           Sonarr/Radarr         qBittorrent
     |                     |                     |
     v                     v                     v
 Overseerr ---------> Sonarr/Radarr ------> qBittorrent
 (demande film    (cherche via Prowlarr,  (telecharge derriere
  ou serie)        selectionne le          VPN Mullvad via
                   meilleur torrent)       Gluetun)
     |                     |                     |
     |                     v                     v
     |              Prowlarr interroge     /downloads/incomplete
     |              les indexeurs            puis
     |              (Cpasbien, 1337x,      /downloads/complete
     |               RuTracker, etc.)
     |
     |
[4] IMPORT            [5] SYNC              [6] LECTURE
Sonarr/Radarr          rclone                Player Freebox
     |                     |                     |
     v                     v                     v
 Sonarr/Radarr      rclone move            Le player Freebox
 (detecte fichier    films/ et series/      lit directement
  complet, renomme   separement --> freebox les fichiers sur
  et deplace vers    via SFTP sur tunnel    le NVMe interne
  /media/            WireGuard              en 4K direct
  films/ ou          (toutes les 1 min)     play
  series/)
```

### Detail de chaque etape

**1. Demande** — L'utilisateur accede a Overseerr (`overseerr.DOMAIN`) via Authelia (one_factor) et demande un film ou une serie. Overseerr transmet la demande a Radarr (films) ou Sonarr (series).

**2. Recherche** — Sonarr ou Radarr interroge Prowlarr, qui agrege les resultats de multiples indexeurs torrent. Le meilleur torrent est selectionne selon les profils de qualite (ex: 4K FR, priorite aux Remux).

**3. Telechargement** — Sonarr/Radarr envoie le torrent a qBittorrent (accessible via `gluetun:8080` sur le reseau Docker). qBittorrent telecharge derriere le VPN Mullvad. Les fichiers transitent par `/downloads/incomplete` puis `/downloads/complete`.

**4. Import** — Sonarr/Radarr detecte la fin du telechargement, renomme le fichier selon les conventions, et cree un **hardlink** vers `/data/media/films/` ou `/data/media/series/` (meme filesystem = meme inode, zero espace supplementaire). Le fichier original reste dans `/data/downloads/` pour le seeding.

**5. Synchronisation** — Le conteneur rclone, en boucle toutes les minutes, deplace (`rclone move`) les films et series separement vers la Freebox via SFTP sur le tunnel WireGuard. Les fichiers partiels (`*.part`, `*.!qB`) sont exclus. Les repertoires source vides sont supprimes (`--delete-empty-src-dirs`).

**6. Lecture** — Le player integre de la Freebox Ultra lit directement les fichiers sur le stockage NVMe interne. Le contenu est disponible en 4K direct play sur le reseau local.

---

## Securite

L'architecture applique une defense en profondeur avec plusieurs couches de protection.

### Vue d'ensemble des couches

```
Couche 1 : Cloudflare          IP VPS masquee, protection DDoS, proxy SSL
Couche 2 : Nginx               HTTPS force, headers securite, auth_request → Authelia
Couche 3 : Authelia SSO        Portail unique, one_factor ou two_factor selon service
Couche 4 : Fail2ban            Ban IP sur echecs SSH et auth
Couche 5 : SSH durci           Port custom, password desactive, root desactive
Couche 6 : VPN Mullvad         IP reelle jamais exposee pour les torrents
Couche 7 : Tunnel WireGuard    Transferts VPS-Freebox chiffres, SFTP non expose
Couche 8 : Docker hardened     no-new-privileges, logs limites, userland-proxy off, socket :ro
```

### Isolation reseau

- **qBittorrent** : aucune stack reseau propre, tout passe par Gluetun. Si le VPN tombe, le conteneur est totalement isole (kill switch natif).
- **Ports internes** : tous lies a `127.0.0.1` (8080, 9696, 8989, 7878, 5055, 7575, 9091). Aucun service Docker n'est directement accessible depuis Internet.
- **SFTP Freebox** : accessible uniquement via le tunnel WireGuard, pas d'exposition sur Internet.

### Conteneurs securises

| Mesure | Conteneurs concernes |
|---|---|
| `no-new-privileges:true` | Tous sauf Gluetun et Fail2ban |
| `network_mode: service:gluetun` | qBittorrent (isolation VPN) |
| Volumes `:ro` | rclone (source media), fail2ban (logs), docker.sock |
| Healthchecks | Gluetun (VPN actif), Prowlarr (API accessible), Authelia (API health) |

### Nginx et headers HTTP

Tous les vhosts appliquent :
- `Strict-Transport-Security: max-age=31536000; includeSubDomains` (HSTS)
- `X-Frame-Options: SAMEORIGIN` (protection clickjacking)
- `X-Content-Type-Options: nosniff` (protection MIME sniffing)
- `Referrer-Policy: strict-origin-when-cross-origin`
- Redirection HTTP vers HTTPS systematique
- TLSv1.2 et TLSv1.3 uniquement (pas de TLSv1.0/1.1)
- `ssl_prefer_server_ciphers on` avec selection de ciphers securisee

### Authentification

- **Authelia SSO** : portail unique d'authentification. Overseerr en one_factor, tous les services admin en two_factor (TOTP). Les endpoints `/api` de Sonarr et Radarr sont exclus pour la communication inter-services (authentification par API key).
- **SFTP** : cle publique SSH uniquement, mot de passe desactive, sudo desactive.
- **SSH VPS** : port custom (`SSH_PORT`), authentification par mot de passe desactivee, login root desactive.

### Mises a jour automatiques

- **Watchtower** : met a jour les images Docker tous les jours a 3h00, nettoie les anciennes images
- **unattended-upgrades** : mises a jour de securite systeme automatiques (configure par `harden.sh`)

### Donnees sensibles

Toutes les valeurs sensibles (cles WireGuard, credentials, tokens, secrets Authelia) sont dans les fichiers `.env` qui ne sont jamais commites (`.gitignore`). Les fichiers versionnes ne contiennent que des templates avec des placeholders.
