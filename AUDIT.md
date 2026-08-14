# Audit du déploiement Plausible CE

Date : 2026-08-14 · Dépôt : `Fox-Target/plausible-community-edition`

## 1. Méthode et limites

Ce qui a pu être vérifié :

- comparaison ligne à ligne du dépôt avec l'amont `plausible/community-edition` (historique complet cloné) ;
- disponibilité réelle des images (`ghcr.io/plausible/community-edition`, `clickhouse/clickhouse-server`, `postgres`) interrogée directement sur les registries ;
- validation des fichiers `compose.yml` / `compose.low-resources.yml` (`docker compose config`) et des XML ClickHouse ;
- validation de `config/deploy.yml` avec Kamal 2.12.0 (`kamal config`), et inspection des commandes `docker run` que Kamal produit pour l'application et les deux accessoires ;
- lecture du code de Plausible v3.2.1 (routes de health, gestion de `X-Forwarded-For`, conditions d'activation du TLS interne) et de kamal-proxy ;
- notes de version amont v2.1.5 → v3.2.1 et commits de correctifs.

Ce qui n'a **pas** pu être vérifié : l'exécution réelle des conteneurs (pas de démon Docker dans l'environnement d'audit) et l'état du VPS (logs, RAM, disque). Les causes de la panne sont donc classées par probabilité, avec pour chacune la commande de diagnostic qui tranche. Le §5 donne le bloc de commandes à lancer sur le VPS.

## 2. État du dépôt

| | Avant | Après |
| --- | --- | --- |
| Base amont | état du 2024-12-09 (`c29a0f0`) | **v3.2.1** (2026-05-15) |
| Image Plausible | `v2.1.4` (oct. 2024) | **`v3.2.1`** |
| ClickHouse | `24.3.3.102-alpine` | **`24.12-alpine`** |
| Postgres | `16-alpine` | `16-alpine` (inchangé, volontairement) |
| Réglages « low resources » CH | présents mais **inactifs** | actifs (`users.d/`) |
| `CLICKHOUSE_SKIP_USER_SETUP` | absent | présent |
| Tweak local `ERL_FLAGS` | présent | **conservé** |

Le fork n'avait pas divergé de l'amont autrement que par le commit `434ed81` (`ERL_FLAGS`), qui a été préservé.

## 3. Constats

### P1 — Les réglages « faibles ressources » de ClickHouse n'étaient jamais appliqués

**Cause.** `clickhouse/low-resources.xml` déclarait le profil sous `<profile><default>` et était monté dans `config.d/`. Or les profils de settings se déclarent sous `<profiles>` (pluriel) et sont lus depuis `users.d/`, pas `config.d/`. Le bloc était donc silencieusement ignoré : `max_threads` restait au nombre de cœurs, le parsing/formatage parallèle restait actif, etc.

**Preuve.** Bug de l'amont, corrigé par le commit `f602706` « Fix low resources settings for Clickhouse » (2026-01-02), livré dans la release v3.2.0 dont les notes indiquent explicitement que les réglages mémoire ClickHouse *« weren't actually applied »*.

**Conséquence sur un petit VPS.** ClickHouse consomme bien plus de mémoire que prévu à l'ingestion et aux requêtes → OOM killer → conteneur tué et redémarré en boucle, ce qui fait échouer le healthcheck et donc le `docker compose up`.

**Correctif appliqué.** `clickhouse/default-profile-low-resources-overrides.xml` monté dans `users.d/`, `low-resources.xml` réduit au seul `mark_cache_size`, `CLICKHOUSE_SKIP_USER_SETUP=1` ajouté (sinon l'entrypoint de l'image régénère une config utilisateur qui écrase le profil).

### P2 — Healthcheck trop serré : `dependency failed to start: container plausible_events_db is unhealthy`

**Cause.** Le `compose.yml` amont ne fixe que `start_period: 1m`. Le reste prend les valeurs Docker par défaut : `interval 30s`, `timeout 30s`, `retries 3`. ClickHouse doit donc répondre sur `/ping` en **~2 min 30 au pire**, sinon le conteneur passe `unhealthy`, et comme le service `plausible` a `depends_on: condition: service_healthy`, `docker compose up -d` s'arrête en erreur.

**Pourquoi « ça marchait avant, puis plus jamais ».** C'est le profil de panne le plus cohérent avec la description : le temps de démarrage de ClickHouse croît avec le nombre de parts sur disque et dépend fortement des I/O. Sur un VPS lent dont le volume `event-data` a grossi, on finit par franchir le seuil — de façon définitive, et sans que rien n'ait changé côté configuration.

**Correctif appliqué.** `compose.low-resources.yml` (opt-in) porte les deux bases à `start_period: 5m`, `interval: 10s`, `retries: 30`.

**Diagnostic.** `docker inspect --format '{{json .State.Health}}' plausible-ce-plausible_events_db-1 | jq` et les logs du conteneur.

### P3 — Mémoire insuffisante / pas de swap

L'amont recommande **2 Go de RAM minimum** pour ClickHouse + Plausible. Trois processus lourds cohabitent (BEAM, ClickHouse, Postgres). Sans swap, l'OOM killer frappe pendant `db migrate` — l'étape la plus gourmande, et justement celle qui s'exécute au déploiement.

**Diagnostic :** `dmesg -T | grep -i -E 'oom|killed process'`, `docker inspect --format '{{.State.OOMKilled}}' <conteneur>`.

**Correctifs proposés :** activer un fichier de swap (§6) et utiliser `compose.low-resources.yml`, qui plafonne ClickHouse à 50 % de la RAM visible (`max_server_memory_usage_to_ram_ratio`) et ramène le cache de marques de 500 Mio à 128 Mio.

### P4 — Retard de version : 20 mois, et sauts de version obligatoires

L'image `v2.1.4` date d'octobre 2024. L'amont est passé par v2.1.5, v3.0.0, v3.0.1, v3.1.0, v3.2.0 puis v3.2.1. Les correctifs ne sont pas rétroportés sur les anciennes versions. Par ailleurs Plausible v3 est publié avec ClickHouse **24.12** : rester sur 24.3 n'était pas une combinaison testée par l'amont.

### P5 — Sécurité : ne pas s'arrêter à v3.2.0

Les versions **v3.0.0-rc.0 → v3.2.0** exposent un endpoint HTTP `/storybook` permettant une **exécution de code à distance** (CVE-2026-8467 / GHSA-55hg-8qxv-qj4p). La v3.2.1 le supprime. Le dépôt cible donc directement **v3.2.1** ; il ne faut pas s'arrêter en chemin sur une v3.0/3.1/3.2.0.

### P6 — Échec possible au `pull` : limites Docker Hub

Postgres et ClickHouse viennent de Docker Hub, dont les pulls anonymes sont limités (aujourd'hui **100 pulls / 6 h par IP**). Sur une IP partagée ou après plusieurs tentatives de redéploiement, le pull échoue avec `toomanyrequests: You have reached your unauthenticated pull rate limit`. Les trois images référencées ont été vérifiées comme toujours présentes et multi-architectures (amd64/arm64), donc ce n'est pas une image disparue.

**Correctif :** `docker login` sur le VPS avec un compte Docker gratuit avant `docker compose pull`.

### P7 — Saturation du disque

Deux sources typiques sur un petit disque : les logs Docker `json-file`, non bornés par défaut, et les images obsolètes accumulées à chaque mise à jour. Un disque plein produit des erreurs de déploiement variées (`no space left on device`, ClickHouse qui refuse de démarrer). `compose.low-resources.yml` borne désormais les logs à 3 × 10 Mio par service.

**Diagnostic :** `df -h`, `docker system df`.

### P8 — `SECRET_KEY_BASE` d'au moins 64 octets

La v3 est stricte là-dessus (le README amont l'a explicité). Une clé plus courte fait échouer le démarrage de l'application. `openssl rand -base64 48` produit bien une chaîne de 64 caractères — à vérifier dans le `.env` existant.

### P9 — Ne pas toucher à la version de Postgres

Le dépôt reste sur `postgres:16-alpine`, comme l'amont. Passer le tag à 17 ou 18 rendrait le volume `db-data` illisible (`database files are incompatible with server`) et demanderait un `pg_upgrade` ou un dump/restore. C'est un piège classique lors d'une « remise à jour » globale : il a été volontairement évité.

## 4. Ce qui a changé dans le dépôt

- `config/deploy.yml` — **nouveau**, configuration Kamal 2 (voir §7).
- `.kamal/secrets.example` — **nouveau**, modèle de fichier de secrets.
- `compose.yml` — aligné sur l'amont v3.2.1 (images v3.2.1 + ClickHouse 24.12, `CLICKHOUSE_SKIP_USER_SETUP=1`, montage `users.d/`), avec `ERL_FLAGS` conservé.
- `clickhouse/default-profile-low-resources-overrides.xml` — **nouveau** (correctif P1).
- `clickhouse/low-resources.xml` — réduit à `mark_cache_size`.
- `clickhouse/tiny-vps.xml` — **nouveau**, overrides mémoire pour < 2 Go (opt-in).
- `compose.low-resources.yml` — **nouveau**, surcouche opt-in (healthchecks, mémoire, logs).
- `README.md` — version amont v3.2.1 + section « Notes de ce fork ».
- `.gitignore` — nouveaux fichiers ajoutés à la liste blanche.

## 5. Diagnostic à lancer sur le VPS

À exécuter dans le répertoire du déploiement, **avant** toute mise à jour :

```sh
# ressources
free -h; swapon --show; nproc; df -h

# état des conteneurs et raison des arrêts
docker compose ps
docker inspect --format '{{.Name}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} health={{if .State.Health}}{{.State.Health.Status}}{{end}}' $(docker compose ps -aq)

# le message d'erreur exact
docker compose logs --tail 200 plausible_events_db
docker compose logs --tail 200 plausible

# OOM killer côté hôte
dmesg -T | grep -i -E 'oom|killed process' | tail -20

# place disque prise par Docker
docker system df
```

Les trois signatures à repérer :

| Signature | Constat |
| --- | --- |
| `dependency failed to start: container ... is unhealthy` | P2 (et souvent P1/P3 en amont) |
| `oom=true`, `Killed process` dans `dmesg` | P3 (+ P1) |
| `toomanyrequests` / `no space left on device` | P6 / P7 |

Côté Kamal, l'équivalent :

```sh
kamal app details                      # conteneurs et versions en place
kamal app logs --lines 200
kamal accessory logs events-db --lines 200
kamal proxy logs --lines 200           # échecs de healthcheck, TLS, routage
```

| Signature | Constat |
| --- | --- |
| `Health check failed` / timeout au déploiement | K1 (chemin `/up`) ou K2 (`deploy_timeout`) |
| `manifest unknown` / `not found` au pull | K3 (`--version` absent) |
| `unauthorized` au pull | K4 (identifiants de registre) |
| certificat Let's Encrypt jamais émis | K5 (ports 80/443 déjà pris) |

## 6. Procédure de mise à jour recommandée

```sh
# 0. Faire de la place et sauvegarder (le rollback d'une v3 vers v2 n'est pas supporté)
docker system prune -af
docker compose exec -T plausible_db pg_dump -U postgres -d plausible_db | gzip > ~/plausible-pg-$(date +%F).sql.gz

# ClickHouse : sauvegarde du volume, stack arrêtée (pas de disque de backup configuré ici)
docker compose down
docker run --rm -v plausible-ce_event-data:/data:ro -v "$PWD":/backup alpine \
  tar czf /backup/clickhouse-$(date +%F).tar.gz -C /data .
# ajuster le nom du volume si besoin : docker volume ls | grep event-data

# 1. Swap, si absent (recommandé sous 2 Go de RAM)
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 2. Récupérer cette version du dépôt (le .env et compose.override.yml ne sont pas suivis)
git pull

# 3. Vérifier SECRET_KEY_BASE >= 64 caractères
awk -F= '/^SECRET_KEY_BASE=/{print length($2)}' .env

# 4. Éviter la limite Docker Hub
docker login

# 5. Démarrer (surcouche petite config)
docker compose -f compose.yml -f compose.low-resources.yml pull
docker compose -f compose.yml -f compose.low-resources.yml up -d

# 6. Suivre la migration : elle est longue en v2 -> v3, ne pas l'interrompre
docker compose logs -f plausible
```

Si un `compose.override.yml` existe (exposition des ports 80/443), il est chargé automatiquement en plus — inutile de le passer en `-f`, mais vérifier qu'il ne référence plus l'ancienne version d'image.

## 7. Déploiement avec Kamal

Le déploiement cible est **Kamal 2** (validé ici avec la version 2.12.0 : `kamal config` passe et les commandes `docker run` produites ont été inspectées). `config/deploy.yml` décrit un rôle applicatif `web` et deux accessoires, `db` (Postgres) et `events-db` (ClickHouse), tous sur le réseau docker `kamal`, ce qui permet la résolution DNS par nom de conteneur (`plausible-db`, `plausible-events-db`).

Les constats P1, P3, P4 à P9 du §3 restent valables tels quels. En revanche P2 (healthcheck Compose) et la surcouche `compose.low-resources.yml` ne s'appliquent pas : Kamal a ses propres mécanismes, avec ses propres pièges.

### K1 — Le healthcheck par défaut de kamal-proxy échoue toujours

kamal-proxy interroge **`/up`** par défaut. Plausible n'expose pas cette route : elle renvoie 404, le proxy ne bascule jamais le trafic, et **tous** les déploiements échouent en timeout. C'est l'équivalent Kamal du constat P2 — et la première chose à vérifier si un déploiement Kamal a échoué par le passé.

Endpoints réellement disponibles :

| Route | Comportement |
| --- | --- |
| `/api/health` | 200 seulement si Postgres **et** ClickHouse **et** les caches **et** les sessions sont prêts |
| `/api/system/health/live` | 200 dès que la VM répond (pas de vérification des bases) |
| `/api/system/health/ready` | identique à `/api/health` |

`config/deploy.yml` utilise `/api/health` : c'est le bon choix, le trafic n'est basculé que sur une instance réellement fonctionnelle.

### K2 — `deploy_timeout` par défaut (30 s) contre une migration v2 → v3

La commande du conteneur enchaîne `db createdb`, `db migrate` puis `run` : le port n'est ouvert qu'une fois les migrations terminées, ce qui peut prendre plusieurs minutes sur un petit VPS. Avec les 30 s par défaut, Kamal abandonne avant. Le fichier fixe `deploy_timeout: 900`.

### K3 — `--version` est obligatoire

On déploie une image amont, sans build local. Kamal doit donc être appelé avec `-P` (skip build & push) **et** `--version` :

```sh
kamal setup  -P --version=v3.2.1   # première installation
kamal deploy -P --version=v3.2.1   # mises à jour
```

Sans `--version`, Kamal prend le SHA git de *ce dépôt* comme tag d'image ; ce tag n'existe pas sur ghcr.io et le `docker pull` échoue sur le serveur. C'est aussi ce tag qui sert de nom de conteneur (`plausible-web-v3.2.1`) et de cible de `kamal rollback`.

### K4 — Identifiants de registre exigés même pour une image publique

`ghcr.io/plausible/community-edition` est public, mais la validation Kamal impose `registry/username` et `registry/password` dès que le serveur n'est pas `localhost`. Un PAT GitHub avec le seul scope `read:packages` suffit ; il se déclare dans `.kamal/secrets` sous `KAMAL_REGISTRY_PASSWORD`. De même, `builder/arch` doit être renseigné alors que rien n'est construit (`amd64`, ou `arm64` si le VPS est ARM), sinon la configuration est refusée au chargement.

### K5 — TLS : un seul terminateur

kamal-proxy occupe les ports **80 et 443** et gère Let's Encrypt (`proxy/ssl: true`). Il faut donc :

- **ne pas définir `HTTPS_PORT`** — cette variable est le seul déclencheur du Let's Encrypt interne de Plausible ; définie, elle ferait démarrer un second serveur ACME en conflit avec le proxy ;
- définir `HTTP_PORT: "8000"` et `proxy/app_port: 8000` ;
- garder `BASE_URL` en `https://…` (c'est lui qui détermine le cookie `secure`) ;
- **arrêter l'ancienne pile Compose avant le premier `kamal setup`**, sinon les ports 80/443 sont déjà pris et l'émission du certificat échoue.

Sans `HTTPS_PORT`, la redirection HTTPS interne de Plausible reste désactivée : pas de risque de boucle de redirection derrière le proxy.

### K6 — Ne pas activer `forward_headers`

Plausible détermine l'IP du visiteur en prenant la **première** valeur de `X-Forwarded-For`. Avec `ssl: true`, kamal-proxy réécrit cet en-tête avec l'IP réelle du client : c'est le comportement voulu. Activer `forward_headers: true` lui ferait au contraire conserver l'en-tête envoyé par le client, qui passerait alors en première position — n'importe quel visiteur pourrait falsifier son IP, donc son pays, dans les statistiques. À laisser désactivé tant que rien d'autre (Cloudflare, un autre proxy) n'est placé devant.

### K7 — Les accessoires ne sont pas gérés par `kamal deploy`

Deux conséquences pratiques :

- **Modifier un fichier `clickhouse/*.xml` n'a aucun effet sur un simple `kamal deploy`.** Les fichiers déclarés sous `files:` sont téléversés au boot de l'accessoire ; il faut `kamal accessory reboot events-db` (arrêt/redémarrage du conteneur, donc courte interruption).
- **Aucun ordonnancement ni healthcheck entre accessoires et application.** Au tout premier démarrage, l'application peut boucler en redémarrages tant que ClickHouse n'est pas prêt ; c'est normal et sans gravité, `deploy_timeout` laisse le temps. Pour éviter le bruit, booter les accessoires d'abord :

```sh
kamal accessory boot all
kamal accessory logs events-db --follow   # attendre "Ready for connections"
kamal deploy -P --version=v3.2.1
```

### K8 — Les données ne sont plus au même endroit qu'avec Compose

Kamal ne crée pas de volumes docker nommés pour les accessoires : il monte des répertoires du serveur, relatifs au répertoire de connexion SSH (`$PWD`, typiquement `/root`) :

| Donnée | Compose | Kamal |
| --- | --- | --- |
| Postgres | volume `plausible-ce_db-data` | `~/plausible-db/data` |
| ClickHouse | volume `plausible-ce_event-data` | `~/plausible-events-db/data` |
| Logs ClickHouse | volume `plausible-ce_event-logs` | `~/plausible-events-db/logs` |
| Config ClickHouse | bind depuis le dépôt | `~/plausible-events-db/etc/clickhouse-server/…` |
| Données Plausible (certs, tmp) | volume `plausible-ce_plausible-data` | volume `plausible-data` (déclaré dans `volumes:`) |

**Migrer une installation Compose existante ne se fait donc pas tout seul.** Le plus sûr, pour Postgres, est un dump/restore ; pour ClickHouse, une copie du contenu du volume, propriétaire rétabli :

```sh
# Postgres : dump depuis l'ancienne pile
docker compose exec -T plausible_db pg_dump -U postgres -d plausible_db | gzip > pg.sql.gz

# ClickHouse : copie du volume vers l'emplacement attendu par Kamal
docker compose down
docker run --rm -v plausible-ce_event-data:/from:ro -v /root/plausible-events-db/data:/to \
  alpine sh -c 'cp -a /from/. /to/'
docker run --rm -v /root/plausible-events-db/data:/data alpine \
  sh -c 'chown -R 101:101 /data'   # vérifier l'UID réel : docker run --rm clickhouse/clickhouse-server:24.12-alpine id clickhouse

# puis, après kamal setup, restaurer Postgres
gunzip -c pg.sql.gz | kamal accessory exec db -i --reuse "psql -U postgres -d plausible_db"
```

Tester d'abord sur une copie : une restauration ClickHouse ratée est bien plus coûteuse qu'un dump refait.

### K9 — Ce que Kamal ajoute sur un VPS déjà juste

kamal-proxy est un conteneur Go supplémentaire (empreinte faible, quelques dizaines de Mo) et Kamal conserve l'ancien conteneur applicatif le temps du basculement : pendant un déploiement, **deux instances de Plausible tournent brièvement en parallèle**. Sur une machine à 1 Go, c'est le moment le plus tendu ; le swap du §6 devient ici une nécessité, pas un confort.

### Aide-mémoire

```sh
kamal setup  -P --version=v3.2.1      # bootstrap serveur + accessoires + déploiement
kamal deploy -P --version=v3.2.1      # déploiement suivant
kamal app logs --follow               # logs applicatifs
kamal accessory logs events-db -f     # logs ClickHouse
kamal accessory reboot events-db      # après modification des XML ClickHouse
kamal app exec -i --reuse "/entrypoint.sh db migrate"
kamal rollback v3.1.0                 # bascule sur un conteneur encore présent
kamal proxy logs --follow             # diagnostic TLS / routage
```

## 8. Points restés ouverts

- La cause exacte de la panne d'origine n'est pas prouvée faute d'accès aux logs du VPS : P2 et P1+P3 sont les hypothèses les plus probables, le §5 permet de trancher en une minute.
- Les valeurs de `compose.low-resources.yml` et `clickhouse/tiny-vps.xml` sont calibrées pour 1–2 Go de RAM ; elles méritent d'être ajustées si le VPS est plus (ou moins) doté.
- Sous ~1 Go de RAM, même après ces correctifs, ClickHouse reste au-dessus de ce que la machine peut absorber confortablement : ajouter du swap est alors un pansement, pas une solution.
