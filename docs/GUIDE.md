# Guide d'installation et d'utilisation - Media Stack

Guide complet pour deployer et utiliser le Media Stack self-hosted : telechargement automatise sur VPS derriere VPN, synchronisation vers Freebox Ultra, lecture 4K direct play via le player Freebox.

---

## Table des matieres

1. [Prerequis](#1-prerequis)
2. [Installation Freebox](#2-installation-freebox)
3. [Installation VPS](#3-installation-vps)
4. [Configuration post-demarrage](#4-configuration-post-demarrage)
5. [Utilisation quotidienne](#5-utilisation-quotidienne)
6. [Test de validation end-to-end](#6-test-de-validation-end-to-end)
7. [Commandes utiles](#7-commandes-utiles)
8. [Depannage](#8-depannage)

---

## 1. Prerequis

### 1.1 Materiel requis

| Element | Specifications minimales | Recommande |
|---|---|---|
| **VPS** | 4 vCPU, 8 Go RAM, 500 Go SSD, 1 Gbit/s | Hetzner AX22 (Helsinki) |
| **Freebox Ultra** | Modele avec Docker integre et NVMe interne | Freebox Ultra |
| **Connexion internet** | Fibre stable | Free fibre FTTH |

> **Note** : Le VPS doit etre localise dans un pays ou le telechargement via torrent est tolere (Finlande, Pays-Bas...). Helsinki est le choix par defaut dans cette stack.

### 1.2 Comptes necessaires

Avant de commencer, il faut creer ces comptes :

| Compte | Usage | Lien |
|---|---|---|
| **Mullvad VPN** | Protection torrent (WireGuard) | mullvad.net |
| **Cloudflare** | DNS + proxy + certificats SSL | cloudflare.com |
| **Hetzner** (ou autre) | Hebergement VPS | hetzner.com |

### 1.3 Connaissances requises

- **SSH** : savoir se connecter a un serveur distant via terminal
- **Docker** : comprendre les bases (conteneurs, images, docker compose)
- **Terminal Linux** : naviguer dans les fichiers, editer avec `nano` ou `vim`
- **DNS** : savoir creer des enregistrements A dans un panneau DNS

### 1.4 Logiciels a installer sur le poste local

- Un client SSH (terminal natif sur Mac/Linux, PuTTY ou Windows Terminal sur Windows)
- Git (pour cloner le repo)

---

## 2. Installation Freebox

La Freebox heberge un serveur SFTP (reception des fichiers depuis le VPS). La lecture se fait directement via le player Freebox integre. On configure la Freebox en premier car le VPS a besoin des informations WireGuard.

### 2.1 Activer Docker dans Freebox OS

1. Ouvrir un navigateur et aller sur **mafreebox.freebox.fr**
2. Se connecter avec le mot de passe administrateur
3. Aller dans **Parametres** > **Machines virtuelles**
4. Verifier que la fonctionnalite VM/Docker est activee
5. Si Docker n'est pas disponible directement, il faut creer une VM Debian/Ubuntu et y installer Docker

> **Attention** : Docker sur Freebox Ultra fonctionne via le systeme de VM. Il faut une VM Linux configuree avec Docker installe dedans.

### 2.2 Configurer WireGuard dans Freebox OS

Le serveur WireGuard de la Freebox permet au VPS de se connecter via un tunnel chiffre pour transferer les fichiers.

**Etape 1 : Activer le serveur VPN WireGuard**

```
Freebox OS > Parametres > Mode avance > Connexion Internet > Serveur VPN
```

- Cliquer sur l'onglet **WireGuard**
- Cocher **Activer**
- Cliquer sur **Appliquer**

**Etape 2 : Creer un utilisateur VPN**

```
Serveur VPN > Utilisateurs > Ajouter
```

Remplir les champs :

| Champ | Valeur |
|---|---|
| Login | `mediastack` |
| Type | WireGuard |
| IP fixe | Laisser celle proposee (ex: `192.168.27.65`) |
| Keepalive | `25` |

**Etape 3 : Telecharger le fichier de configuration**

- Cliquer sur le bouton de telechargement a cote de l'utilisateur cree
- Telecharger le fichier `.conf`
- Ce fichier contient toutes les valeurs necessaires pour le `.env` du VPS

Le fichier `.conf` telecharge ressemble a ceci :

```ini
[Interface]
PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890abcde=
Address = 192.168.27.65/32

[Peer]
PublicKey = xYzAbCdEfGhIjKlMnOpQrStUvWxYz1234567890xyz=
Endpoint = 82.123.45.67:22563
AllowedIPs = 192.168.27.64/32
PersistentKeepalive = 25
```

> **Note** : Garde ce fichier precieusement. Tu en auras besoin pour remplir le `.env` du VPS a l'etape 3.

**Correspondance fichier .conf vers variables .env du VPS :**

| Valeur dans le .conf | Variable .env du VPS |
|---|---|
| `[Interface] PrivateKey` | `WG_FREEBOX_PRIVATE_KEY` |
| `[Interface] Address` | `WG_FREEBOX_ADDRESS` |
| `[Peer] PublicKey` | `WG_FREEBOX_PUBLIC_KEY` |
| `[Peer] Endpoint` (IP sans le port) | `WG_FREEBOX_ENDPOINT` |
| `[Peer] AllowedIPs` (IP sans le /32) | `FREEBOX_WG_IP` |

### 2.3 Cloner le repo et configurer .env

Se connecter en SSH a la VM Docker de la Freebox, puis :

```bash
# Cloner le projet
git clone https://github.com/<TON_USER_GITHUB>/media-stack.git
cd media-stack/freebox

# Creer le fichier .env
cp .env.example .env
nano .env
```

### 2.4 Remplir le fichier freebox/.env

Voici chaque variable avec son explication :

| Variable | Description | Exemple |
|---|---|---|
| `PUID` | ID utilisateur Linux (laisser 1000 par defaut) | `1000` |
| `PGID` | ID groupe Linux (laisser 1000 par defaut) | `1000` |
| `TZ` | Fuseau horaire | `Europe/Paris` |
| `MEDIA_PATH` | Chemin des medias dans la VM | `/data/media` |
| `SFTP_USER` | Nom utilisateur pour la connexion SFTP | `mediastack` |

Exemple de fichier `.env` complet :

```env
PUID=1000
PGID=1000
TZ=Europe/Paris

MEDIA_PATH=/data/media

SFTP_USER=mediastack
```

### 2.5 Lancer le script d'installation

```bash
bash scripts/setup-freebox.sh
```

Le script effectue les operations suivantes :

1. **Verifie Docker** : s'assure que Docker et Docker Compose v2 sont disponibles
2. **Cree les repertoires** :
   - `/mnt/NVMe/media/films` et `/mnt/NVMe/media/series` pour les medias
3. **Prepare le conteneur SFTP** : cree le repertoire `config/sftp/ssh/`
4. **Copie .env.example vers .env** si le fichier n'existe pas encore
5. **Verifie les variables** : s'arrete si des valeurs `CHANGE_ME` restent
6. **Demande la cle SSH publique du VPS** : cette cle sera utilisee par rclone pour se connecter en SFTP. Tu l'obtiendras lors de l'installation du VPS (etape 3)
7. **Demande confirmation** puis lance `docker compose up -d`

> **Note** : Si tu n'as pas encore la cle SSH du VPS, laisse le champ vide et appuie sur Entree. Tu pourras l'ajouter manuellement plus tard dans `config/sftp/ssh/authorized_key`.

A la fin, tu verras :

```
  SFTP  -> port 2222 (via tunnel WireGuard)
```

### 2.6 Services lances sur la Freebox

| Service | Port | Role |
|---|---|---|
| **SFTP** | 2222 | Reception des fichiers depuis le VPS via WireGuard |

---

## 3. Installation VPS

Le VPS est le coeur du systeme : il gere les demandes, le telechargement via VPN, et la synchronisation vers la Freebox.

### 3.1 Preparer le serveur

**Creer le VPS** chez Hetzner (ou autre fournisseur) :

- OS : Ubuntu 22.04 LTS ou Debian 12
- Localisation : Helsinki (Finlande) recommande
- SSH : ajouter ta cle SSH publique a la creation

**Se connecter au VPS :**

```bash
ssh root@IP_DU_VPS
```

**Installer Git :**

```bash
apt update && apt install -y git
```

**Cloner le projet :**

```bash
git clone https://github.com/<TON_USER_GITHUB>/media-stack.git
cd media-stack/vps
```

### 3.2 Configurer le fichier .env

```bash
cp .env.example .env
nano .env
```

Voici chaque variable avec son explication detaillee :

#### Variables systeme

| Variable | Description | Valeur par defaut |
|---|---|---|
| `PUID` | ID utilisateur Linux | `1000` |
| `PGID` | ID groupe Linux | `1000` |
| `TZ` | Fuseau horaire | `Europe/Paris` |

#### Chemin racine du stockage

| Variable | Description | Valeur par defaut |
|---|---|---|
| `DATA_PATH` | Racine du volume de stockage (contient `downloads/` et `media/`) | `/mnt/HC_Volume_XXXXXX` (ID de votre volume Hetzner) |

> **Important** : `downloads/` et `media/` doivent etre sur le **meme filesystem** pour que les hardlinks fonctionnent (Sonarr/Radarr cree un hardlink au lieu de copier, economisant 100% d'espace disque pendant le seeding).

#### VPN Mullvad WireGuard (pour les torrents)

| Variable | Description | Comment l'obtenir |
|---|---|---|
| `WIREGUARD_PRIVATE_KEY` | Cle privee WireGuard Mullvad | Generer sur mullvad.net > Compte > Config WireGuard |
| `WIREGUARD_ADDRESSES` | Adresse IP WireGuard Mullvad | Fournie avec la cle (ex: `10.66.123.45/32`) |

Pour generer ces valeurs :

1. Se connecter sur mullvad.net
2. Aller dans **Compte** > **WireGuard configuration**
3. Generer une nouvelle cle
4. Copier la cle privee et l'adresse IP

#### Tunnel WireGuard VPS vers Freebox

Ces valeurs viennent du **fichier .conf telecharge a l'etape 2.2** :

| Variable | Description | Exemple |
|---|---|---|
| `WG_FREEBOX_PRIVATE_KEY` | Cle privee du tunnel (section `[Interface]`) | `aBcDeFgHiJkL...` |
| `WG_FREEBOX_ADDRESS` | Adresse IP du VPS dans le tunnel | `192.168.27.65/32` |
| `WG_FREEBOX_PUBLIC_KEY` | Cle publique de la Freebox (section `[Peer]`) | `xYzAbCdEfGhI...` |
| `WG_FREEBOX_ENDPOINT` | IP publique de la Freebox (**sans le port**) | `82.123.45.67` |
| `WG_FREEBOX_PORT` | Port WireGuard de la Freebox | `22563` (defaut) |

#### Freebox SFTP (pour rclone)

| Variable | Description | Exemple |
|---|---|---|
| `FREEBOX_WG_IP` | IP WireGuard de la Freebox dans le tunnel | `192.168.27.64` |
| `FREEBOX_SFTP_PORT` | Port SFTP du conteneur sur la Freebox | `2222` (defaut) |
| `FREEBOX_SFTP_USER` | Utilisateur SFTP | `mediastack` (defaut) |
| `FREEBOX_MEDIA_PATH` | Chemin des medias cote Freebox | `/data` (defaut) |

#### Domaine et nginx

| Variable | Description | Exemple |
|---|---|---|
| `DOMAIN` | Domaine pointant vers le VPS | `media.exemple.fr` |

#### Authelia SSO

| Variable | Description | Exemple |
|---|---|---|
| `AUTHELIA_JWT_SECRET` | Secret JWT (min 32 chars) | `openssl rand -hex 32` |
| `AUTHELIA_SESSION_SECRET` | Secret session (min 32 chars) | `openssl rand -hex 32` |
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | Cle chiffrement stockage (min 32 chars) | `openssl rand -hex 32` |
| `AUTHELIA_USER` | Nom d'utilisateur SSO | `admin` |
| `AUTHELIA_PASSWORD` | Mot de passe SSO (hashe en Argon2id par setup.sh) | `UnMotDePasseSecure123!` |
| `AUTHELIA_EMAIL` | Email de l'utilisateur | `admin@exemple.fr` |

#### Homepage (Dashboard)

| Variable | Description | Exemple |
|---|---|---|
| `HOMEPAGE_RADARR_KEY` | Cle API Radarr pour Homepage | Copier depuis Radarr > Settings > General |
| `HOMEPAGE_SONARR_KEY` | Cle API Sonarr pour Homepage | Copier depuis Sonarr > Settings > General |
| `HOMEPAGE_PROWLARR_KEY` | Cle API Prowlarr pour Homepage | Copier depuis Prowlarr > Settings > General |
| `HOMEPAGE_OVERSEERR_KEY` | Cle API Overseerr pour Homepage | Copier depuis Overseerr > Settings > General |

#### Notifications

| Variable | Description | Exemple |
|---|---|---|
| `DISCORD_WATCHTOWER_WEBHOOK_ID` | ID webhook Discord salon #systeme (Watchtower) | Partie ID de l'URL webhook Discord |
| `DISCORD_WATCHTOWER_WEBHOOK_TOKEN` | Token webhook Discord salon #systeme (Watchtower) | Partie token de l'URL webhook Discord |

#### SSH et divers

| Variable | Description | Valeur par defaut |
|---|---|---|
| `SSH_PORT` | Port SSH personnalise (pour le durcissement) | `2222` |
| `PORT_QBITTORRENT` | Port interne qBittorrent | `8080` |

Exemple de fichier `.env` complet :

```env
PUID=1000
PGID=1000
TZ=Europe/Paris

DATA_PATH=/mnt/HC_Volume_XXXXXX

WIREGUARD_PRIVATE_KEY=maClePriveeMullvadIciEnBase64=
WIREGUARD_ADDRESSES=10.66.123.45/32

WG_FREEBOX_PRIVATE_KEY=maClePriveeTunnelIci=
WG_FREEBOX_ADDRESS=192.168.27.65/32
WG_FREEBOX_PUBLIC_KEY=clePubliqueFreebox=
WG_FREEBOX_ENDPOINT=82.123.45.67
WG_FREEBOX_PORT=22563

FREEBOX_WG_IP=192.168.27.64
FREEBOX_SFTP_PORT=2222
FREEBOX_SFTP_USER=mediastack
FREEBOX_MEDIA_PATH=/data

DOMAIN=media.exemple.fr

AUTHELIA_JWT_SECRET=generez_avec_openssl_rand_hex_32
AUTHELIA_SESSION_SECRET=generez_avec_openssl_rand_hex_32
AUTHELIA_STORAGE_ENCRYPTION_KEY=generez_avec_openssl_rand_hex_32
AUTHELIA_USER=admin
AUTHELIA_PASSWORD=UnMotDePasseSecure123!
AUTHELIA_EMAIL=admin@exemple.fr

HOMEPAGE_RADARR_KEY=votreCleApiRadarr
HOMEPAGE_SONARR_KEY=votreCleApiSonarr
HOMEPAGE_PROWLARR_KEY=votreCleApiProwlarr
HOMEPAGE_OVERSEERR_KEY=votreCleApiOverseerr

DISCORD_WATCHTOWER_WEBHOOK_ID=123456789
DISCORD_WATCHTOWER_WEBHOOK_TOKEN=votreTokenWebhook

SSH_PORT=2222
PORT_QBITTORRENT=8080
```

### 3.3 Lancer le script d'installation

```bash
bash scripts/setup.sh
```

Voici ce que fait chaque etape du script :

| Etape | Action | Detail |
|---|---|---|
| 1 | **Verification prerequis** | Installe Docker, Docker Compose, inotify-tools et WireGuard si absents |
| 2 | **Creation repertoires** | Cree `/data/downloads/complete`, `/data/downloads/incomplete`, `/data/media/films`, `/data/media/series` |
| 3 | **Generation cle SSH** | Cree une cle Ed25519 dans `config/rclone/id_rsa` pour la connexion SFTP vers la Freebox |
| 4 | **Copie .env** | Copie `.env.example` vers `.env` si le fichier n'existe pas |
| 5 | **Verification variables** | Verifie qu'aucune variable ne contient encore `CHANGE_ME` |
| 6 | **Tunnel WireGuard** | Genere `/etc/wireguard/wg-freebox.conf` et active le tunnel vers la Freebox |
| 7 | **Generation rclone.conf** | Configure rclone pour la connexion SFTP vers la Freebox via le tunnel |
| 8 | **Scan cle hote SFTP** | Enregistre la cle du serveur SFTP Freebox dans `known_hosts` |
| 9 | **Affiche la cle SSH publique** | **A copier** pour la coller cote Freebox dans `config/sftp/ssh/authorized_key` |
| 10 | **Configuration Authelia** | Genere le hash Argon2id du mot de passe, configure users_database.yml |
| 11 | **Configuration nginx** | Installe nginx, deploie la config reverse proxy avec auth_request Authelia |
| 12 | **Durcissement systeme** | Propose de lancer `harden.sh` (optionnel mais recommande) |
| 13-15 | **Lancement Docker** | Demande confirmation puis lance `docker compose up -d` |
| 16 | **Healthchecks** | Attend que Gluetun, Prowlarr et Authelia soient healthy (timeout 120s) |
| 17 | **Resume** | Affiche les URLs de tous les services |

> **Attention** : A l'etape 9, le script affiche une cle SSH publique. **Copie-la** et retourne sur la Freebox pour la coller dans `freebox/config/sftp/ssh/authorized_key`. Sans cette cle, rclone ne pourra pas se connecter pour synchroniser les fichiers.

### 3.4 Copier la cle SSH sur la Freebox

Apres l'execution de `setup.sh`, le script affiche une cle publique SSH. Il faut la copier sur la Freebox :

```bash
# Sur la Freebox (VM Docker), dans le repertoire du projet
echo "ssh-ed25519 AAAA... media-stack-rclone" > freebox/config/sftp/ssh/authorized_key

# Redemarrer le conteneur SFTP pour prendre en compte la cle
cd freebox && docker compose restart sftp
```

### 3.5 Durcissement systeme (harden.sh)

Le script `harden.sh` est propose automatiquement par `setup.sh`. Il est **fortement recommande** de l'executer. Voici ce qu'il fait :

| Action | Detail |
|---|---|
| **SSH hardening** | Desactive l'authentification par mot de passe, desactive le login root, change le port SSH vers celui defini dans `.env` (defaut: 2222) |
| **Tweaks kernel** | Active les SYN cookies, le filtrage reverse path, ignore les broadcasts ICMP, restreint l'acces a dmesg |
| **Mises a jour auto** | Installe et configure `unattended-upgrades` pour les patchs de securite |
| **Docker hardening** | Configure le daemon Docker : logs limites (10 Mo x 3), userland-proxy desactive, no-new-privileges global, live-restore active |

> **Attention** : Apres l'execution de `harden.sh`, **ne ferme pas ta session SSH**. Ouvre un nouveau terminal et teste la connexion avec le nouveau port :
>
> ```bash
> ssh -p 2222 utilisateur@IP_DU_VPS
> ```
>
> Si ca fonctionne, tu peux fermer l'ancienne session. Sinon, tu as toujours la session ouverte pour corriger.

### 3.6 Configurer Cloudflare DNS

Aller dans le **Cloudflare Dashboard** > ton domaine > **DNS**.

Creer les enregistrements A suivants (tous pointent vers l'IP du VPS) :

| Type | Nom | Contenu | Proxy |
|---|---|---|---|
| A | `auth` | IP du VPS | Active (orange) |
| A | `overseerr` | IP du VPS | Active (orange) |
| A | `sonarr` | IP du VPS | Active (orange) |
| A | `radarr` | IP du VPS | Active (orange) |
| A | `prowlarr` | IP du VPS | Active (orange) |
| A | `qbittorrent` | IP du VPS | Active (orange) |
| A | `home` | IP du VPS | Active (orange) |
| A | `logs` | IP du VPS | Active (orange) |
| A | `jackett` | IP du VPS | Active (orange) |

Exemple concret avec le domaine `media.exemple.fr` :

```
auth.media.exemple.fr         ->  95.217.xx.xx  (Proxy ON)
overseerr.media.exemple.fr    ->  95.217.xx.xx  (Proxy ON)
sonarr.media.exemple.fr       ->  95.217.xx.xx  (Proxy ON)
radarr.media.exemple.fr       ->  95.217.xx.xx  (Proxy ON)
prowlarr.media.exemple.fr     ->  95.217.xx.xx  (Proxy ON)
qbittorrent.media.exemple.fr  ->  95.217.xx.xx  (Proxy ON)
home.media.exemple.fr         ->  95.217.xx.xx  (Proxy ON)
logs.media.exemple.fr         ->  95.217.xx.xx  (Proxy ON)
jackett.media.exemple.fr      ->  95.217.xx.xx  (Proxy ON)
```

> **Note** : Le proxy Cloudflare (icone orange) masque l'IP reelle du VPS et offre une protection DDoS gratuite.

### 3.7 Certificats SSL Cloudflare Origin

Les certificats Origin permettent le chiffrement entre Cloudflare et ton VPS.

1. Dans Cloudflare Dashboard > **SSL/TLS** > **Origin Server**
2. Cliquer sur **Create Certificate**
3. Laisser les options par defaut (RSA 2048, 15 ans)
4. Dans **Hostnames**, ajouter `*.media.exemple.fr` et `media.exemple.fr`
5. Cliquer sur **Create**
6. Copier le **Origin Certificate** et la **Private Key**

Sur le VPS, creer les fichiers :

```bash
# Creer le repertoire
mkdir -p /etc/ssl/cloudflare

# Coller le certificat
nano /etc/ssl/cloudflare/cert.pem
# (coller le contenu du Origin Certificate)

# Coller la cle privee
nano /etc/ssl/cloudflare/key.pem
# (coller le contenu de la Private Key)

# Securiser les permissions
chmod 600 /etc/ssl/cloudflare/key.pem
chmod 644 /etc/ssl/cloudflare/cert.pem
```

Dans Cloudflare > **SSL/TLS** > **Overview**, mettre le mode SSL sur **Full (strict)**.

### 3.8 Configurer le Firewall Hetzner

Dans la console Hetzner Cloud, configurer le firewall avec ces regles :

**Regles entrantes (Inbound) :**

| Protocole | Port | Source | Usage |
|---|---|---|---|
| TCP | 2222 (ou `SSH_PORT`) | `0.0.0.0/0, ::/0` | SSH |
| TCP | 80 | `0.0.0.0/0, ::/0` | HTTP (redirect HTTPS) |
| TCP | 443 | `0.0.0.0/0, ::/0` | HTTPS |
| UDP | 443 | `0.0.0.0/0, ::/0` | HTTP/3 QUIC |

**Regles sortantes (Outbound) :** tout autoriser (defaut Hetzner).

> **Note** : Aucun port de service interne (Sonarr 8989, Radarr 7878, etc.) ne doit etre ouvert. Tout passe par nginx sur le port 443.

### 3.9 Services lances sur le VPS

| Service | Port interne | Role |
|---|---|---|
| **Gluetun** | 8080 (qBittorrent) | VPN Mullvad WireGuard pour les torrents |
| **qBittorrent** | via Gluetun | Client torrent (protege par le VPN) |
| **Prowlarr** | 9696 | Gestionnaire d'indexeurs torrent |
| **Sonarr** | 8989 | Gestionnaire de series TV |
| **Radarr** | 7878 | Gestionnaire de films |
| **Overseerr** | 5055 | Interface de demande utilisateur |
| **Homepage** | 7575 (→3000 interne) | Dashboard de monitoring |
| **Dozzle** | 9999 | Visualiseur de logs Docker |
| **Byparr** | 8192 | Bypass Cloudflare pour indexeurs Prowlarr |
| **Jackett** | 9117 | Indexeur supplementaire (fallback Cloudflare) |
| **Authelia** | 9091 | SSO — portail d'authentification unique (2FA TOTP) |
| **rclone** | - | Synchronisation VPS vers Freebox (toutes les minutes) |
| **Fail2ban** | - | Protection brute-force SSH et nginx |
| **Watchtower** | - | Mise a jour automatique des images Docker (3h du matin) |

---

## 4. Configuration post-demarrage

Une fois les services lances, il faut les configurer dans cet ordre precis.

### 4.1 Prowlarr - Indexeurs torrent

Acceder a `https://prowlarr.DOMAIN` (ex: `https://prowlarr.media.exemple.fr`).

> **Note** : Tu seras redirige vers Authelia pour t'authentifier (two_factor pour les services admin).

**Premiere connexion** : Prowlarr demandera de creer un compte admin. Choisis un nom d'utilisateur et un mot de passe.

**Ajouter les indexeurs** : Aller dans **Indexers** > **Add Indexer**.

Indexeurs recommandes a ajouter :

| Indexeur | Type | Priorite | Comment l'ajouter |
|---|---|---|---|
| **Cpasbien** | Public | 1 | Chercher "Cpasbien" dans la liste, activer |
| **OxTorrent** | Public | 2 | Chercher "OxTorrent", activer |
| **1337x** | Public | 3 | Chercher "1337x", activer |
| **RuTracker** | Semi-prive | 4 | Chercher "RuTracker", entrer identifiants (inscription gratuite sur rutracker.org) |
| **Sharewood** | Prive | 5 | Uniquement sur invitation. Si tu as un compte, chercher "Sharewood" et entrer les identifiants |

Pour chaque indexeur :

1. Cliquer sur **Add Indexer**
2. Chercher le nom de l'indexeur
3. Configurer les eventuels identifiants
4. Cliquer sur **Test** pour verifier que ca fonctionne
5. Sauvegarder

**Configurer le proxy Byparr (pour les indexeurs derriere Cloudflare)** :

Si certains indexeurs sont proteges par Cloudflare, il faut configurer Byparr comme proxy :

1. Aller dans **Settings** > **Indexer Proxies**
2. Ajouter un nouveau proxy de type **FlareSolverr**
3. URL : `http://byparr:8191`
4. Tag : `flaresolverr`
5. Sauvegarder
6. Appliquer le tag `flaresolverr` sur les indexeurs concernes

**Configurer la synchronisation avec Sonarr et Radarr** :

1. Aller dans **Settings** > **Apps**
2. Cliquer sur **+** et ajouter **Radarr**
   - Prowlarr Server : `http://prowlarr:9696` (ou `http://localhost:9696`)
   - Radarr Server : `http://radarr:7878`
   - API Key : copier depuis Radarr > Settings > General > API Key
3. Faire de meme pour **Sonarr** (`http://sonarr:8989`)

### 4.2 Radarr - Gestion des films

Acceder a `https://radarr.DOMAIN`.

**Connecter Prowlarr (indexeurs)** :

1. **Settings** > **Indexers**
2. Si tu as configure la synchronisation dans Prowlarr (etape precedente), les indexeurs apparaissent automatiquement
3. Sinon, ajouter manuellement via **Add Indexer** > **Torznab** avec l'URL Prowlarr

**Ajouter qBittorrent comme client de telechargement** :

1. **Settings** > **Download Clients** > **+**
2. Choisir **qBittorrent**
3. Remplir :

| Champ | Valeur |
|---|---|
| Name | `qBittorrent` |
| Host | `gluetun` |
| Port | `8080` |
| Username | `admin` |
| Password | Celui de qBittorrent (voir note ci-dessous) |

> **Note** : Au premier demarrage, qBittorrent genere un mot de passe temporaire visible dans les logs. Pour le recuperer :
>
> ```bash
> docker logs qbittorrent 2>&1 | grep "temporary password"
> ```
>
> Connecte-toi ensuite a qBittorrent via `https://qbittorrent.DOMAIN` pour changer le mot de passe dans **Options** > **Web UI**.

4. Cliquer sur **Test** puis **Save**

**Creer un profil de qualite "4K FR"** :

1. **Settings** > **Profiles** > cliquer sur un profil existant ou en creer un nouveau
2. Nommer le profil `4K FR`
3. Dans **Qualities**, cocher et classer par ordre de preference :
   - Remux-2160p (le meilleur)
   - Bluray-2160p
   - WEB-2160p
   - Bluray-1080p (fallback)
4. Dans **Language**, mettre French en priorite, English en fallback
5. Sauvegarder

**Configurer le chemin racine (Root Folder)** :

1. **Settings** > **Media Management**
2. Ajouter un Root Folder : `/data/media/films`

### 4.3 Sonarr - Gestion des series

Acceder a `https://sonarr.DOMAIN`.

La configuration est identique a Radarr :

1. **Verifier les indexeurs** : s'ils sont synchronises via Prowlarr, ils apparaissent automatiquement
2. **Ajouter qBittorrent** : meme configuration que Radarr (host: `gluetun`, port: `8080`)
3. **Creer un profil de qualite** similaire a celui de Radarr
4. **Root Folder** : `/data/media/series`

### 4.4 Overseerr - Interface de demande

Acceder a `https://overseerr.DOMAIN`.

> **Note** : Overseerr utilise son authentification interne (pas de SSO Authelia). C'est plus simple pour les amis et la famille qui n'ont pas besoin de 2FA.

**Configuration initiale** :

1. **Connecter Radarr** :
   - Aller dans **Settings** > **Services**
   - Cliquer sur **Add Radarr Server**
   - Remplir :

| Champ | Valeur |
|---|---|
| Server Name | `Radarr` |
| Hostname | `radarr` (nom du conteneur) |
| Port | `7878` |
| API Key | Copier depuis Radarr > Settings > General |
| Quality Profile | Selectionner le profil `4K FR` |
| Root Folder | `/data/media/films` |

2. **Connecter Sonarr** : meme procedure avec le port `8989` et le Root Folder `/data/media/series`

3. **Configurer les utilisateurs** : dans **Settings** > **Users**, definir les permissions pour les utilisateurs qui pourront faire des demandes

### 4.5 Homepage - Dashboard

Acceder a `https://home.DOMAIN`.

Homepage sert de tableau de bord centralise pour acceder rapidement a tous les services.

**Configuration** :

Homepage se configure via des fichiers YAML dans le repertoire `config/homepage/` :

- **`services.yaml`** : definition des services affiches sur le dashboard (Sonarr, Radarr, Overseerr, qBittorrent, etc.)
- **`widgets.yaml`** : widgets d'information (systeme, recherche, etc.)
- **`settings.yaml`** : parametres generaux du dashboard (titre, theme, layout, etc.)

Les cles API des services sont passees en variables d'environnement (`HOMEPAGE_RADARR_KEY`, `HOMEPAGE_SONARR_KEY`, etc.) et referencees dans les fichiers YAML.

> **Note** : Homepage n'a pas d'authentification interne. L'acces est protege par Authelia (two_factor).

---

## 5. Utilisation quotidienne

### 5.1 Demander un film ou une serie

1. Ouvrir **Overseerr** (`https://overseerr.DOMAIN`)
2. Utiliser la barre de recherche pour trouver un film ou une serie
3. Cliquer sur le resultat souhaite
4. Cliquer sur **Request**
5. Confirmer la demande

La demande est automatiquement transmise a Radarr (films) ou Sonarr (series), qui cherchent via les indexeurs Prowlarr et envoient le telechargement a qBittorrent.

### 5.2 Suivre un telechargement

Plusieurs endroits pour suivre l'avancement :

- **Overseerr** : la demande passe de "Requested" a "Available" quand tout est pret
- **Radarr/Sonarr** : onglet **Activity** pour voir l'etat du telechargement
- **qBittorrent** (`https://qbittorrent.DOMAIN`) : detail complet du torrent (vitesse, progression, peers)

### 5.3 Verifier la synchronisation

La synchronisation VPS vers Freebox se fait automatiquement :

- **Conteneur rclone** : sync automatique toutes les **minutes**
- **sync-watch.sh** (optionnel) : detection en temps reel via inotify

Pour verifier manuellement :

```bash
# Voir les logs de synchronisation rclone
docker logs -f rclone

# Verifier les fichiers sur le VPS
ls -la /data/media/films/
ls -la /data/media/series/
```

La synchronisation est transparente : une fois le telechargement termine et le fichier deplace par Sonarr/Radarr dans `/data/media/`, rclone le detecte et le transfere vers la Freebox via le tunnel WireGuard chiffre.

### 5.4 Acceder au contenu

Les medias synchronises sont disponibles directement sur le NVMe de la Freebox Ultra. Le player Freebox integre lit les fichiers en 4K direct play depuis le reseau local.

---

## 6. Test de validation end-to-end

Apres avoir tout installe et configure, voici le scenario de test complet pour verifier que toute la chaine fonctionne.

### Etape 1 : Faire une demande

1. Ouvrir **Overseerr** (`https://overseerr.DOMAIN`)
2. Chercher un film recent disponible en 4K (ex: un blockbuster recent)
3. Cliquer sur **Request**

### Etape 2 : Verifier la recherche

1. Ouvrir **Radarr** (`https://radarr.DOMAIN`)
2. Aller dans **Activity**
3. Verifier que Radarr a lance une recherche et trouve un resultat

### Etape 3 : Verifier le telechargement

1. Ouvrir **qBittorrent** (`https://qbittorrent.DOMAIN`)
2. Verifier que le torrent est actif et en cours de telechargement
3. **Verifier que l'IP est celle de Mullvad** (pas l'IP du VPS) :

```bash
# Sur le VPS
docker exec gluetun wget -qO- https://ipinfo.io/json
```

Le resultat doit montrer une IP Mullvad (pas l'IP de ton VPS).

### Etape 4 : Verifier la synchronisation

1. Attendre que le telechargement soit termine
2. Verifier que Radarr a deplace le fichier dans `/data/media/films/`
3. Verifier les logs rclone :

```bash
docker logs rclone --tail 20
```

4. Attendre le prochain cycle de sync (max 1 min) ou verifier que le fichier est synchronise

### Etape 5 : Verifier sur la Freebox

1. Verifier que le fichier est present sur le NVMe (`/mnt/NVMe/media/films/`)
2. Lancer la lecture via le player Freebox pour confirmer que tout fonctionne

Si toutes les etapes sont validees, ta stack est operationnelle.

---

## 7. Commandes utiles

### Verification du VPN

```bash
# Verifier que qBittorrent tourne bien derriere le VPN Mullvad
docker exec gluetun wget -qO- https://ipinfo.io/json
```

### Verification du tunnel WireGuard

```bash
# Etat du tunnel
wg show wg-freebox

# Test de connectivite vers la Freebox
ping -c 3 FREEBOX_WG_IP
```

### Logs des services

```bash
# Logs de synchronisation rclone
docker logs -f rclone

# Logs d'un service specifique
docker logs -f sonarr
docker logs -f radarr
docker logs -f gluetun

# Status de tous les services
docker compose ps
```

### Mise a jour

```bash
# Mettre a jour toutes les images et redemarrer
docker compose pull && docker compose up -d
```

> **Note** : Watchtower fait cette operation automatiquement tous les jours a 3h du matin.

### Fail2ban

```bash
# Voir le status general
docker exec fail2ban fail2ban-client status

# Voir les IPs bannies sur nginx
docker exec fail2ban fail2ban-client status nginx-auth
```

### nginx

```bash
# Tester la configuration
nginx -t

# Recharger apres modification
nginx -t && systemctl reload nginx
```

### Sync avancee (optionnel)

Le script `sync-watch.sh` offre une synchronisation en temps reel en complement du conteneur rclone :

```bash
# Lancer en arriere-plan sur le VPS
nohup bash scripts/sync-watch.sh &
```

Fonctionnalites :

- Detection instantanee des nouveaux fichiers via inotify
- Verification de stabilite du fichier (30 secondes)
- Retry automatique avec backoff exponentiel (10s, 30s, 90s)
- Notifications webhook Discord/Slack
- Sync complete de secours toutes les heures

---

## 8. Depannage

### qBittorrent ne demarre pas

qBittorrent depend de Gluetun (le VPN). Si Gluetun n'est pas healthy, qBittorrent ne demarrera pas.

```bash
# Verifier l'etat de Gluetun
docker logs gluetun --tail 30

# Verifier le healthcheck
docker inspect --format='{{.State.Health.Status}}' gluetun
```

Causes possibles :
- Cle WireGuard Mullvad incorrecte dans `.env`
- Serveur Mullvad indisponible (changer `SERVER_COUNTRIES` dans `docker-compose.yml`)

### Le tunnel WireGuard ne fonctionne pas

```bash
# Verifier l'etat du tunnel
wg show wg-freebox

# Redemarrer le tunnel
wg-quick down wg-freebox && wg-quick up wg-freebox
```

Causes possibles :
- Le serveur WireGuard n'est pas active sur la Freebox
- L'IP publique de la Freebox a change (mettre a jour `WG_FREEBOX_ENDPOINT`)

### rclone ne synchronise pas

```bash
# Verifier les logs
docker logs rclone --tail 30
```

Causes possibles :
- La cle SSH n'est pas dans `authorized_key` cote Freebox
- Le tunnel WireGuard est inactif
- Le conteneur SFTP n'est pas demarre sur la Freebox

### Les fichiers n'apparaissent pas sur la Freebox

1. Verifier que les fichiers sont presents dans `/mnt/NVMe/media/` sur la Freebox
2. Verifier les permissions :

```bash
# Sur la Freebox
ls -la /mnt/NVMe/media/films/
ls -la /mnt/NVMe/media/series/
```

### Les services ne sont pas accessibles via le navigateur

1. Verifier que les DNS Cloudflare sont corrects
2. Verifier que nginx tourne :

```bash
systemctl status nginx
nginx -t
```

3. Verifier que les conteneurs tournent :

```bash
docker compose ps
```

4. Verifier que le mode SSL Cloudflare est sur **Full (strict)** (compatible avec les certificats Cloudflare Origin)
