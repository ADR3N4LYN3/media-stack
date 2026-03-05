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

- **VPS Hetzner AX22** (Helsinki) : telechargement automatise derriere VPN Mullvad, gestion des medias, reverse proxy HTTPS
- **Freebox Ultra** (domicile) : stockage NVMe interne, lecture Plex 4K direct play

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
    |             /    |    |    |    \                       |
    |            /     |    |    |     \                      |
    |     overseerr sonarr radarr prowlarr homarr            |
    |         |        |    |       |                         |
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
    |                    /data/media/                         |
    |                   +-- films/                            |
    |                   +-- series/                           |
    |                            |                           |
    |                    [plex] <--- lecture 4K               |
    |                       |                                |
    |                  port 32400                             |
    ==========================================================
```

### Roles des composants

| Composant | Emplacement | Role |
|---|---|---|
| nginx | VPS (host) | Reverse proxy HTTPS, terminaison SSL Cloudflare |
| Overseerr | VPS | Interface de demande utilisateur (films/series) |
| Sonarr | VPS | Gestion automatisee des series TV |
| Radarr | VPS | Gestion automatisee des films |
| Prowlarr | VPS | Agregateur d'indexeurs torrent |
| qBittorrent | VPS | Client torrent derriere VPN |
| Gluetun | VPS | Tunnel VPN Mullvad WireGuard pour qBittorrent |
| rclone | VPS | Synchronisation SFTP VPS vers Freebox |
| Fail2ban | VPS | Protection brute-force SSH et nginx BasicAuth |
| Watchtower | VPS | Mise a jour automatique des images Docker |
| Plex | Freebox | Serveur media, lecture 4K direct play |
| SFTP | Freebox | Reception des fichiers depuis le VPS |

---

## Services Docker VPS

Le VPS execute 10 conteneurs Docker definis dans `vps/docker-compose.yml`. Tous partagent le reseau `media_network` (sauf exceptions notees).

### 1. Gluetun

Passerelle VPN obligatoire pour tout le trafic torrent.

| Propriete | Valeur |
|---|---|
| Image | `qmcgaw/gluetun:latest` |
| Ports | `127.0.0.1:${PORT_QBITTORRENT}:8080` (WebUI qBittorrent) |
| Reseau | `media_network` |
| Capabilities | `NET_ADMIN`, `NET_RAW`, `CHOWN`, `DAC_OVERRIDE` |
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
| Volumes | `./config/qbittorrent:/config`, `${DOWNLOADS_PATH}:/downloads` |
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
| Volumes | `./config/sonarr:/config`, `${DOWNLOADS_PATH}/complete:/downloads/complete`, `${MEDIA_PATH}/series:/tv` |
| Dependance | `prowlarr` (condition: `service_healthy`) |
| Security | `no-new-privileges:true` |

### 5. Radarr

Gestion automatisee des films.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/radarr:latest` |
| Ports | `127.0.0.1:7878:7878` |
| Reseau | `media_network` |
| Volumes | `./config/radarr:/config`, `${DOWNLOADS_PATH}/complete:/downloads/complete`, `${MEDIA_PATH}/films:/movies` |
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

Overseerr est le seul service sans BasicAuth nginx (il possede sa propre authentification interne).

### 7. Homarr

Dashboard de monitoring centralise.

| Propriete | Valeur |
|---|---|
| Image | `ghcr.io/homarr-labs/homarr:latest` |
| Ports | `127.0.0.1:7575:7575` |
| Reseau | `media_network` |
| Volumes | `./config/homarr/configs:/app/data/configs`, `./config/homarr/icons:/app/public/icons`, `./config/homarr/data:/data` |
| Security | `no-new-privileges:true` |

Necessite une cle de chiffrement (`HOMARR_SECRET_KEY`, 64 caracteres hex).

### 8. rclone

Synchronisation automatique des medias du VPS vers la Freebox via SFTP sur tunnel WireGuard.

| Propriete | Valeur |
|---|---|
| Image | `rclone/rclone:latest` |
| Ports | Aucun |
| Reseau | `network_mode: host` |
| Entrypoint | `/bin/sh -c` (boucle infinie) |
| Volumes | `${MEDIA_PATH}:/source:ro`, `./config/rclone:/config/rclone:ro`, `./config/rclone/id_rsa:/root/.ssh/id_rsa:ro` |
| Dependances | `sonarr`, `radarr` |
| Security | `no-new-privileges:true` |

**Fonctionnement :**
- Boucle toutes les 5 minutes (300 secondes)
- Commande : `rclone sync /source freebox:${FREEBOX_MEDIA_PATH}`
- Parametres : 4 transferts, 8 checkers, 4 multi-thread streams, buffer 64M
- Exclusions : `*.part`, `*.!qB` (fichiers en cours de telechargement)
- Authentification : cle SSH privee montee en lecture seule

**Configuration rclone** (`vps/config/rclone/rclone.conf.template`) :
- Remote `freebox` de type SFTP
- Connexion via IP WireGuard de la Freebox, port 2222
- Authentification par cle SSH
- Chunk size : 32M, concurrency : 4

### 9. Fail2ban

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
| `sshd` | SSH | `/var/log/auth.log` | 3 | 24h |
| `nginx-auth` | HTTP/HTTPS | `/var/log/nginx/error.log` | 5 | 1h |

**Filtre nginx-auth** (`vps/fail2ban/filter.d/nginx-auth.conf`) — detecte :
- Aucun user/password fourni pour BasicAuth
- Utilisateur non trouve
- Mot de passe incorrect

### 10. Watchtower

Mise a jour automatique des images Docker.

| Propriete | Valeur |
|---|---|
| Image | `containrrr/watchtower:latest` |
| Reseau | `media_network` |
| Volumes | `/var/run/docker.sock:/var/run/docker.sock` |
| Security | `no-new-privileges:true` |

**Configuration :**
- Planification : tous les jours a 3h00 (`0 0 3 * * *`)
- Nettoyage des anciennes images : actif
- Conteneurs arretes ignores
- Notifications Slack/Discord optionnelles via webhook

---

## Services Docker Freebox

La Freebox Ultra execute 2 conteneurs dans une VM Docker, definis dans `freebox/docker-compose.yml`.

### 1. Plex

Serveur media pour la lecture 4K direct play.

| Propriete | Valeur |
|---|---|
| Image | `plexinc/pms-docker:latest` |
| Reseau | `network_mode: host` |
| Ports | 32400 (via host) |
| Volumes | `/opt/plex/config:/config`, `/opt/plex/transcode:/transcode`, `${MEDIA_PATH}/films:/data/films:ro`, `${MEDIA_PATH}/series:/data/series:ro` |

**Points cles :**
- Volumes media montes en lecture seule (`:ro`)
- Token `PLEX_CLAIM` necessaire au premier demarrage (expire en 4 minutes)
- Ulimits `nofile` : 65536 (soft et hard)
- GPU passthrough possible (commante dans le compose)

### 2. SFTP

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
  +-- homarr
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

Nginx tourne directement sur le host VPS (pas dans Docker). Il expose 6 sous-domaines via Cloudflare.

```
Internet --> Cloudflare (proxy ON) --> VPS:443 --> nginx --> service local
```

| Sous-domaine | Service | Port local | BasicAuth |
|---|---|---|---|
| `overseerr.DOMAIN` | Overseerr | 5055 | Non (auth interne) |
| `sonarr.DOMAIN` | Sonarr | 8989 | Oui |
| `radarr.DOMAIN` | Radarr | 7878 | Oui |
| `prowlarr.DOMAIN` | Prowlarr | 9696 | Oui |
| `qbittorrent.DOMAIN` | qBittorrent | 8080 | Oui |
| `home.DOMAIN` | Homarr | 7575 | Oui |

**Configuration** (`vps/nginx/media-stack.conf.template`) :
- Redirection HTTP 80 vers HTTPS 443 sur tous les vhosts
- HTTP/2 active
- Certificats SSL Cloudflare Origin (`/etc/ssl/cloudflare/cert.pem` + `key.pem`)
- Protocoles : TLSv1.2 et TLSv1.3 uniquement
- Headers de securite : HSTS, X-Frame-Options, X-Content-Type-Options
- BasicAuth via `/etc/nginx/.htpasswd-media` (genere par `setup.sh`)
- Proxy headers : X-Real-IP, X-Forwarded-For, X-Forwarded-Proto
- WebSocket support sur Overseerr et Homarr (Upgrade + Connection headers)

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
Sonarr/Radarr          rclone                Plex
     |                     |                     |
     v                     v                     v
 Sonarr/Radarr      rclone sync            Plex detecte
 (detecte fichier    /source --> freebox:   les nouveaux
  complet, renomme   via SFTP sur tunnel    fichiers et
  et deplace vers    WireGuard              les rend
  /data/media/       (toutes les 5 min)     disponibles
  films/ ou                                 en 4K direct
  series/)                                  play
```

### Detail de chaque etape

**1. Demande** — L'utilisateur accede a Overseerr (`overseerr.DOMAIN`) et demande un film ou une serie. Overseerr transmet la demande a Radarr (films) ou Sonarr (series).

**2. Recherche** — Sonarr ou Radarr interroge Prowlarr, qui agrege les resultats de multiples indexeurs torrent. Le meilleur torrent est selectionne selon les profils de qualite (ex: 4K FR, priorite aux Remux).

**3. Telechargement** — Sonarr/Radarr envoie le torrent a qBittorrent (accessible via `gluetun:8080` sur le reseau Docker). qBittorrent telecharge derriere le VPN Mullvad. Les fichiers transitent par `/downloads/incomplete` puis `/downloads/complete`.

**4. Import** — Sonarr/Radarr detecte la fin du telechargement, renomme le fichier selon les conventions, et le deplace (hardlink ou copie) vers `/data/media/films/` ou `/data/media/series/`.

**5. Synchronisation** — Le conteneur rclone, en boucle toutes les 5 minutes, synchronise `/data/media/` (monte en lecture seule) vers la Freebox via SFTP sur le tunnel WireGuard. Les fichiers partiels (`*.part`, `*.!qB`) sont exclus.

**6. Lecture** — Plex sur la Freebox detecte automatiquement les nouveaux fichiers sur le stockage NVMe (`/data/media/films/` et `/data/media/series/`, montes en lecture seule). Le contenu est disponible en 4K direct play sur le reseau local.

---

## Securite

L'architecture applique une defense en profondeur avec plusieurs couches de protection.

### Vue d'ensemble des couches

```
Couche 1 : Cloudflare          IP VPS masquee, protection DDoS, proxy SSL
Couche 2 : Nginx               HTTPS force, headers securite, BasicAuth
Couche 3 : Fail2ban            Ban IP sur echecs SSH et BasicAuth
Couche 4 : SSH durci           Port custom, password desactive, root desactive
Couche 5 : VPN Mullvad         IP reelle jamais exposee pour les torrents
Couche 6 : Tunnel WireGuard    Transferts VPS-Freebox chiffres, SFTP non expose
Couche 7 : Docker hardened     no-new-privileges, logs limites, userland-proxy off
```

### Isolation reseau

- **qBittorrent** : aucune stack reseau propre, tout passe par Gluetun. Si le VPN tombe, le conteneur est totalement isole (kill switch natif).
- **Ports internes** : tous lies a `127.0.0.1` (8080, 9696, 8989, 7878, 5055, 7575). Aucun service Docker n'est directement accessible depuis Internet.
- **SFTP Freebox** : accessible uniquement via le tunnel WireGuard, pas d'exposition sur Internet.

### Conteneurs securises

| Mesure | Conteneurs concernes |
|---|---|
| `no-new-privileges:true` | Tous sauf Gluetun et Fail2ban |
| `network_mode: service:gluetun` | qBittorrent (isolation VPN) |
| Volumes `:ro` | rclone (source media), Plex (media), fail2ban (logs) |
| Healthchecks | Gluetun (VPN actif), Prowlarr (API accessible) |

### Nginx et headers HTTP

Tous les vhosts appliquent :
- `Strict-Transport-Security: max-age=31536000; includeSubDomains` (HSTS)
- `X-Frame-Options: SAMEORIGIN` (protection clickjacking)
- `X-Content-Type-Options: nosniff` (protection MIME sniffing)
- Redirection HTTP vers HTTPS systematique
- TLSv1.2 et TLSv1.3 uniquement (pas de TLSv1.0/1.1)

### Authentification

- **BasicAuth nginx** : fichier `.htpasswd-media` genere par `setup.sh` avec `htpasswd`. Protege Sonarr, Radarr, Prowlarr, qBittorrent et Homarr.
- **Overseerr** : authentification interne (pas de BasicAuth, possede sa propre gestion d'utilisateurs).
- **SFTP** : cle publique SSH uniquement, mot de passe desactive, sudo desactive.
- **SSH VPS** : port custom (`SSH_PORT`), authentification par mot de passe desactivee, login root desactive.

### Mises a jour automatiques

- **Watchtower** : met a jour les images Docker tous les jours a 3h00, nettoie les anciennes images
- **unattended-upgrades** : mises a jour de securite systeme automatiques (configure par `harden.sh`)

### Donnees sensibles

Toutes les valeurs sensibles (cles WireGuard, credentials, tokens) sont dans les fichiers `.env` qui ne sont jamais commites (`.gitignore`). Les fichiers versionnes ne contiennent que des templates avec des placeholders.
