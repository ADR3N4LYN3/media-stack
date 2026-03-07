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

- **VPS Hetzner AX22** (Helsinki) : gestion des medias, reverse proxy HTTPS. Accede aux fichiers Freebox via CIFS/SMB sur tunnel WireGuard
- **Freebox Ultra** (domicile) : telechargement automatise derriere VPN Mullvad, stockage NVMe interne, lecture 4K via le player Freebox integre

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
    |             /    |    |    \                            |
    |            /     |    |     \                           |
    |       seerr sonarr radarr prowlarr homepage             |
    |         |        |    |       |    dozzle               |
    |         |        |    |       |    byparr               |
    |         |        |    |       |    jackett              |
    |         +--------+----+-------+                        |
    |                  |                                     |
    |           API qBittorrent -----+                       |
    |           CIFS /mnt/freebox ---+                       |
    |                                |                       |
    |     [fail2ban]  [watchtower]   | tunnel WireGuard      |
    |                                | (wg-freebox:22563)    |
    =========================|=======|=======================
                             |       |
    =========================|=======|=======================
    |       Freebox Ultra (domicile) |                       |
    |                                |                       |
    |                    [gluetun] -----> VPN Mullvad (Finl.) |
    |                        |                               |
    |                  [qbittorrent]                         |
    |                        |                               |
    |              [SMB/NVMe share] ← via routeur Freebox      |
    |                    [jellyfin]                          |
    |                        |                               |
    |                 NVMe interne                           |
    |                /data/                                  |
    |               +-- downloads/                           |
    |               +-- media/                               |
    |                   +-- films/                           |
    |                   +-- series/                          |
    |                        |                               |
    |          [player freebox] ← lecture 4K direct play     |
    =========================================================
```

### Roles des composants

| Composant | Emplacement | Role |
|---|---|---|
| nginx | VPS (host) | Reverse proxy HTTPS, terminaison SSL Cloudflare |
| Authelia | VPS | SSO — portail d'authentification unique (two_factor TOTP) |
| Seerr | VPS | Interface de demande utilisateur (films/series) |
| Sonarr | VPS | Gestion automatisee des series TV |
| Radarr | VPS | Gestion automatisee des films |
| Prowlarr | VPS | Agregateur d'indexeurs torrent |
| qBittorrent | Freebox | Client torrent derriere VPN (telechargement direct NVMe) |
| Gluetun | Freebox | Tunnel VPN Mullvad WireGuard pour qBittorrent |
| Fail2ban | VPS | Protection brute-force SSH et auth nginx |
| Homepage | VPS | Dashboard de monitoring centralise (widgets YAML) |
| Dozzle | VPS | Visualiseur de logs Docker web |
| Byparr | VPS | Bypass Cloudflare pour Prowlarr (remplace FlareSolverr) |
| Jackett | VPS | Indexeur torrent supplementaire |
| Watchtower | VPS | Mise a jour automatique des images Docker |
| SMB (routeur Freebox) | Freebox | Partage NVMe via SMB, monte en CIFS sur le VPS via WireGuard |

---

## Services Docker VPS

Le VPS execute 11 conteneurs Docker definis dans `vps/docker-compose.yml`. Tous partagent le reseau `media_network` (sauf exceptions notees).

### 1. Prowlarr

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

### 2. Sonarr

Gestion automatisee des series TV.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/sonarr:latest` |
| Ports | `127.0.0.1:8989:8989` |
| Reseau | `media_network` |
| Volumes | `./config/sonarr:/config`, `/mnt/freebox:/data` |
| Dependance | `prowlarr` (condition: `service_healthy`) |
| Security | `no-new-privileges:true` |

### 3. Radarr

Gestion automatisee des films.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/radarr:latest` |
| Ports | `127.0.0.1:7878:7878` |
| Reseau | `media_network` |
| Volumes | `./config/radarr:/config`, `/mnt/freebox:/data` |
| Dependance | `prowlarr` (condition: `service_healthy`) |
| Security | `no-new-privileges:true` |

### 4. Seerr

Interface utilisateur pour les demandes de films et series (fork communautaire d'Overseerr).

| Propriete | Valeur |
|---|---|
| Image | `ghcr.io/seerr-team/seerr:latest` |
| Ports | `127.0.0.1:5055:5055` |
| Reseau | `media_network` |
| Volumes | `./config/overseerr:/app/config` |
| Security | `no-new-privileges:true` |

Seerr utilise son authentification interne (pas de SSO Authelia). Ce choix simplifie l'acces pour les amis et la famille qui n'ont pas besoin de 2FA.

### 5. Homepage

Dashboard de monitoring centralise avec widgets YAML.

| Propriete | Valeur |
|---|---|
| Image | `ghcr.io/gethomepage/homepage:latest` |
| Ports | `127.0.0.1:7575:3000` |
| Reseau | `media_network` |
| Volumes | `./config/homepage:/app/config`, `/var/run/docker.sock:/var/run/docker.sock:ro` |
| Security | `no-new-privileges:true` |

Widgets configures : search (Seerr), resources (CPU/RAM/disk systeme + volume Hetzner), datetime.

### 6. Authelia

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
- Seerr : **exclue d'Authelia** (utilise son auth interne, plus adapte aux utilisateurs non-techniques)
- Services admin (Sonarr, Radarr, Prowlarr, qBittorrent, Homepage, Dozzle, Jackett) : `two_factor` (TOTP obligatoire)
- Endpoints API Sonarr/Radarr (`/api`) : exclus de l'auth (communication inter-services via API key)

**Configuration :**
- Backend : fichier YAML local (`users_database.yml`)
- Hash : Argon2id (genere par `setup.sh`)
- Session : 12h expiration, 2h inactivite, 1 mois remember_me
- Stockage : SQLite local
- 2FA : TOTP (30s, 6 digits)

### 7. Fail2ban

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

### 8. Watchtower

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

### 9. Dozzle

Visualiseur de logs Docker en temps reel via interface web.

| Propriete | Valeur |
|---|---|
| Image | `amir20/dozzle:latest` |
| Ports | `127.0.0.1:9999:8080` |
| Reseau | `media_network` |
| Volumes | `/var/run/docker.sock:/var/run/docker.sock:ro` |

### Notifications Discord (pas un conteneur)

Les notifications Discord sont gerees directement par les services via leurs connexions natives (pas de service intermediaire).

| Salon Discord | Source | Evenements |
|---|---|---|
| `#films` | Radarr (webhook Discord natif) | Grab, Import, Upgrade, Manual Interaction |
| `#series` | Sonarr (webhook Discord natif) | Grab, Import, Upgrade, Manual Interaction |
| `#systeme` | Sonarr Health + Radarr Health + Watchtower | Health issues, mises a jour containers |

**Fonctionnement :**
- Sonarr et Radarr envoient les notifications directement via leurs connexions Discord natives (webhook par salon)
- Chaque service a deux connexions : une pour les medias (Grab/Import) et une pour la sante (Health -> #systeme)
- Watchtower envoie ses notifications via Shoutrrr (webhook Discord dans `#systeme`)
- Seerr : notifications Discord desactivees (redondantes avec les Grab)

### 10. Byparr

Bypass Cloudflare pour les indexeurs Prowlarr (remplace FlareSolverr).

| Propriete | Valeur |
|---|---|
| Image | `ghcr.io/thephaseless/byparr:latest` |
| Ports | `127.0.0.1:8192:8191` |
| Reseau | `media_network` |

Utilise par Prowlarr comme proxy pour les indexeurs proteges par Cloudflare.

### 11. Jackett

Indexeur torrent supplementaire, utilise en complement de Prowlarr pour les sites proteges par Cloudflare.

> **Pourquoi Jackett en plus de Prowlarr ?** Prowlarr a un bug architectural (#2572, #2360) : apres avoir resolu un challenge Cloudflare via FlareSolverr/Byparr, Prowlarr jette le body HTML et refait une requete avec ses propres headers, ce que Cloudflare detecte et bloque (403). Jackett n'a pas ce probleme car il utilise directement le HTML retourne par le solver. Jackett sert donc de fallback pour les indexeurs Cloudflare-protected.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/jackett:latest` |
| Ports | `127.0.0.1:9117:9117` |
| Reseau | `media_network` |
| Dependance | `byparr` |
| Security | `no-new-privileges:true` |

---

## Services Docker Freebox

La Freebox Ultra execute 4 conteneurs dans une VM Docker, definis dans `freebox/docker-compose.yml`. La lecture des medias se fait directement via le player Freebox integre (pas de Plex).

### 1. Gluetun

Passerelle VPN obligatoire pour tout le trafic torrent.

| Propriete | Valeur |
|---|---|
| Image | `qmcgaw/gluetun:latest` |
| Ports | `${FREEBOX_WG_IP}:8080:8080` (WebUI qBittorrent, tunnel WireGuard uniquement) |
| Capabilities | `NET_ADMIN`, `NET_RAW` |
| Devices | `/dev/net/tun` |
| Healthcheck | `ip link show tun0 \| grep -q UP` (30s interval, 60s start) |

Configuration VPN identique au VPS (Mullvad WireGuard Finlande) sauf `FIREWALL_OUTBOUND_SUBNETS=192.168.27.0/24` (subnet WireGuard).

### 2. qBittorrent

Client torrent, isole derriere le VPN Gluetun. Telecharge directement sur le NVMe Freebox.

| Propriete | Valeur |
|---|---|
| Image | `linuxserver/qbittorrent:latest` |
| Reseau | `network_mode: service:gluetun` |
| Dependance | `gluetun` (condition: `service_healthy`) |
| Volumes | `./config/qbittorrent:/config`, `${DATA_PATH}:/data` |

### 3. SMB / CIFS (natif, pas un conteneur)

Le NVMe de la Freebox est partage via SMB par le routeur Freebox (adresse `192.168.1.254`). Le VPS monte ce partage en CIFS via le tunnel WireGuard.

- Partage : `//192.168.1.254/NVMe`
- Monte sur le VPS : `/mnt/freebox`
- Options fstab : `credentials=/etc/cifs-credentials,uid=1000,gid=1000,vers=3.0,_netdev,x-systemd.automount`
- Accessible uniquement via le tunnel WireGuard (pas d'exposition Internet)

---

## Reseau

### Reseau Docker `media_network`

```
Reseau bridge : media_network
Subnet : 172.20.0.0/16
Driver : bridge

Conteneurs connectes :
  +-- prowlarr
  +-- sonarr
  +-- radarr
  +-- seerr
  +-- homepage
  +-- authelia
  +-- dozzle
  +-- byparr
  +-- jackett
  +-- watchtower

Conteneurs en mode host :
  +-- fail2ban (acces a iptables host)
```

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
- Utilise par le VPS pour monter le partage CIFS Freebox (`/mnt/freebox`) et acceder a l'API qBittorrent
- Le serveur WireGuard est natif a la Freebox (active dans Freebox OS)

### Nginx reverse proxy

Nginx tourne directement sur le host VPS (pas dans Docker). Il expose 9 sous-domaines via Cloudflare.

```
Internet --> Cloudflare (proxy ON) --> VPS:443 --> nginx --> Authelia (auth_request) --> service local
```

| Sous-domaine | Service | Port local | Authelia |
|---|---|---|---|
| `auth.DOMAIN` | Authelia | 9091 | — (portail lui-meme) |
| `seerr.DOMAIN` | Seerr | 5055 | — (auth interne) |
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
- SSL et headers de securite factorises dans `snippets/ssl-common.conf` (certificats Cloudflare Origin, TLSv1.2/1.3, ciphers, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy)
- Authelia SSO via `auth_request` directive nginx (snippets inclus dans chaque vhost)
- Proxy headers : X-Real-IP, X-Forwarded-For, X-Forwarded-Proto
- WebSocket support sur Seerr et Homepage (Upgrade + Connection headers)
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
Utilisateur           Sonarr/Radarr         qBittorrent (Freebox)
     |                     |                     |
     v                     v                     v
 Seerr -----------> Sonarr/Radarr ------> qBittorrent
 (demande film    (cherche via Prowlarr,  (telecharge sur NVMe
  ou serie)        selectionne le          Freebox derriere VPN
                   meilleur torrent)       Mullvad via Gluetun)
     |                     |                     |
     |                     v                     v
     |              Prowlarr interroge     /downloads/incomplete
     |              les indexeurs            puis
     |              (Cpasbien, 1337x,      /downloads/complete
     |               RuTracker, etc.)
     |
     |
[4] IMPORT                                 [5] LECTURE
Sonarr/Radarr                               Player Freebox
     |                                           |
     v                                           v
 Sonarr/Radarr detectent via API,           Le player Freebox
 accedent aux fichiers via CIFS             lit directement
 (/mnt/freebox), renomment et              les fichiers sur
 creent des hardlinks vers                  le NVMe interne
 /data/Vidéos/                              en 4K direct
                                            play
```

### Detail de chaque etape

**1. Demande** — L'utilisateur accede a Seerr (`seerr.DOMAIN`) et s'authentifie via l'auth interne de Seerr. Il demande un film ou une serie. Seerr transmet la demande a Radarr (films) ou Sonarr (series).

**2. Recherche** — Sonarr ou Radarr interroge Prowlarr, qui agrege les resultats de multiples indexeurs torrent. Le meilleur torrent est selectionne selon les profils de qualite (ex: 4K FR, priorite aux Remux).

**3. Telechargement** — qBittorrent telecharge sur le NVMe Freebox (derriere VPN Mullvad via Gluetun sur la Freebox). Les fichiers transitent par `/downloads/incomplete` puis `/downloads/complete`.

**4. Import** — Sonarr/Radarr detectent via API, accedent aux fichiers via CIFS (`/mnt/freebox`), renomment et creent des hardlinks vers `/data/Vidéos/`. Plus de transit VPS : les fichiers restent sur le NVMe Freebox.

**5. Lecture** — Le player integre de la Freebox Ultra lit directement les fichiers sur le stockage NVMe interne. Le contenu est disponible en 4K direct play sur le reseau local.

---

## Securite

L'architecture applique une defense en profondeur avec plusieurs couches de protection.

### Vue d'ensemble des couches

```
Couche 1 : Cloudflare          IP VPS masquee, protection DDoS, proxy SSL
Couche 2 : Nginx               HTTPS force, headers securite, auth_request → Authelia
Couche 3 : Authelia SSO        Portail unique, two_factor (TOTP) sur les services admin
Couche 4 : Fail2ban            Ban IP sur echecs SSH et auth
Couche 5 : SSH durci           Port custom, password desactive, root desactive
Couche 6 : VPN Mullvad         IP reelle jamais exposee pour les torrents
Couche 7 : Tunnel WireGuard    Transferts VPS-Freebox chiffres, CIFS non expose
Couche 8 : Docker hardened     no-new-privileges, logs limites, userland-proxy off, socket :ro
```

### Isolation reseau

- **qBittorrent** (Freebox) : aucune stack reseau propre, tout passe par Gluetun. Si le VPN tombe, le conteneur est totalement isole (kill switch natif).
- **Ports internes VPS** : tous lies a `127.0.0.1` (9696, 8989, 7878, 5055, 7575, 9091). Aucun service Docker n'est directement accessible depuis Internet.
- **CIFS Freebox** : partage SMB accessible uniquement via le tunnel WireGuard, pas d'exposition sur Internet.

### Conteneurs securises

| Mesure | Conteneurs concernes |
|---|---|
| `no-new-privileges:true` | Tous sauf Fail2ban (VPS) et Gluetun (Freebox) |
| `network_mode: service:gluetun` | qBittorrent sur Freebox (isolation VPN) |
| Volumes `:ro` | fail2ban (logs), docker.sock |
| Healthchecks | Gluetun (VPN actif, Freebox), Prowlarr (API accessible), Authelia (API health) |

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

- **Authelia SSO** : portail unique d'authentification. Tous les services admin en two_factor (TOTP). Seerr utilise son auth interne (exclue d'Authelia). Les endpoints `/api` de Sonarr et Radarr sont exclus pour la communication inter-services (authentification par API key).
- **SSH VPS** : port custom (`SSH_PORT`), authentification par mot de passe desactivee, login root desactive.

### Mises a jour automatiques

- **Watchtower** : met a jour les images Docker tous les jours a 3h00, nettoie les anciennes images
- **unattended-upgrades** : mises a jour de securite systeme automatiques (configure par `harden.sh`)

### Donnees sensibles

Toutes les valeurs sensibles (cles WireGuard, credentials, tokens, secrets Authelia) sont dans les fichiers `.env` qui ne sont jamais commites (`.gitignore`). Les fichiers versionnes ne contiennent que des templates avec des placeholders.
