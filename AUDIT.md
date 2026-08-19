# Audit du déploiement Plausible CE

Date : 2026-08-14 · Dépôt : `Fox-Target/plausible-community-edition`

## 1. Méthode et limites

Ce qui a pu être vérifié :

- comparaison ligne à ligne du dépôt avec l'amont `plausible/community-edition` (historique complet cloné) ;
- disponibilité réelle des images (`ghcr.io/plausible/community-edition`, `clickhouse/clickhouse-server`, `postgres`) interrogée directement sur les registries ;
- validation des fichiers `compose.yml` / `compose.low-resources.yml` (`docker compose config`) et des XML ClickHouse ;
- validation de `config/deploy.yml` + `config/deploy.analytics.yml` avec Kamal 2.12.0 (`kamal config -d analytics`), et inspection des commandes `docker run` que Kamal produit pour l'application et les deux accessoires ;
- lecture du code de Plausible v3.2.1 (routes de health, gestion de `X-Forwarded-For`, conditions d'activation du TLS interne) et de kamal-proxy ;
- notes de version amont v2.1.5 → v3.2.1 et commits de correctifs.

Ce qui n'a **pas** pu être vérifié : l'exécution réelle des conteneurs (pas de démon Docker dans l'environnement d'audit) et l'état du VPS (logs, disque). Les causes de la panne sont donc classées par probabilité, avec pour chacune la commande de diagnostic qui tranche. Le §5 donne le bloc de commandes à lancer sur le VPS.

**Machine cible : `akira`, 2 vCPU / 4 Go de RAM**, déploiement par **Kamal** depuis la branche `kamal` (§7). C'est au-dessus des 2 Go recommandés en amont, ce qui rétrograde nettement l'hypothèse « OOM ». Classement des causes probables :

| Rang | Constat | Pourquoi |
| --- | --- | --- |
| 1 | **K1** — kamal-proxy interroge `/up`, que Plausible n'expose pas | aucun `proxy/healthcheck` n'était défini : le proxy reçoit 404, ne bascule jamais, et le déploiement échoue en timeout quoi qu'il arrive. L'historique de la branche `kamal` (`5min timeout`, `remove timers`, `no cache warmup`, `try`, `retry`) est exactement le symptôme |
| 2 | **P7** — disque saturé | logs Docker non bornés + images accumulées à chaque build ; produit des échecs variés et durables |
| 3 | **P6** — limites de pull Docker Hub | pour Postgres et ClickHouse, typiquement après plusieurs tentatives rapprochées |
| 4 | **P1 + P3** — mémoire | vrai bug de configuration, mais à 4 Go et 2 cœurs son effet est bien moindre : le profil non appliqué ne libérait que `max_threads` à 2 au lieu de 1 |

P2 (healthcheck Docker Compose) ne concerne que l'usage local de `compose.yml` : la pile déployée n'utilise pas Compose.

## 2. État du dépôt

Le dépôt a deux histoires distinctes : la branche par défaut (`v2.1.4`), restée sur l'état amont de décembre 2024, et la branche **`kamal`**, qui est celle réellement déployée et avait déjà été partiellement remise à jour en novembre 2025.

| | Branche `kamal` avant | Après cette fusion |
| --- | --- | --- |
| Image Plausible déployée (`Dockerfile`) | `v3.1.0` — **vulnérable à la CVE-2026-8467** | **`v3.2.1`** |
| ClickHouse | `24.12-alpine` | `24.12-alpine` (inchangé) |
| Postgres | `16-alpine` | `16-alpine` (inchangé, volontairement) |
| Réglages « low resources » CH | présents mais **inactifs** | actifs (`users.d/`) |
| Plafond mémoire ClickHouse | aucun (90 % de la RAM) | 50 % (2 Go sur 4) |
| Healthcheck kamal-proxy | absent → `/up` → 404 | `/api/health` |
| `readiness_delay` / `ELIXIR_APPLICATION_ENV` | présents mais **sans effet** | retirés |
| `ERL_FLAGS`, `TMPDIR`, rotation des logs, `ulimit` CH | absents | ajoutés |
| `compose.yml` (usage local) | `v3.1.0` | `v3.2.1` + correctif `users.d/` |

## 3. Constats

### P1 — Les réglages « faibles ressources » de ClickHouse n'étaient jamais appliqués

**Cause.** `clickhouse/low-resources.xml` déclarait le profil sous `<profile><default>` et était monté dans `config.d/`. Or les profils de settings se déclarent sous `<profiles>` (pluriel) et sont lus depuis `users.d/`, pas `config.d/`. Le bloc était donc silencieusement ignoré : `max_threads` restait au nombre de cœurs, le parsing/formatage parallèle restait actif, etc.

**Preuve.** Bug de l'amont, corrigé par le commit `f602706` « Fix low resources settings for Clickhouse » (2026-01-02), livré dans la release v3.2.0 dont les notes indiquent explicitement que les réglages mémoire ClickHouse *« weren't actually applied »*.

**Conséquence.** ClickHouse consomme plus de mémoire que prévu à l'ingestion et aux requêtes. Sur une machine à 1 Go cela suffit à déclencher l'OOM killer ; sur les **4 Go / 2 vCPU** de ce VPS, l'effet est bien plus modeste — le réglage ignoré revenait surtout à laisser `max_threads` à 2 (le nombre de cœurs) au lieu de 1, et à garder le parsing parallèle actif. C'est un vrai bug à corriger, mais probablement pas la cause de la panne de déploiement.

**Correctif appliqué.** `clickhouse/default-profile-low-resources-overrides.xml` monté dans `users.d/`, `low-resources.xml` réduit au seul `mark_cache_size`, `CLICKHOUSE_SKIP_USER_SETUP=1` ajouté (sinon l'entrypoint de l'image régénère une config utilisateur qui écrase le profil).

### P2 — Healthcheck trop serré : `dependency failed to start: container plausible_events_db is unhealthy`

**Cause.** Le `compose.yml` amont ne fixe que `start_period: 1m`. Le reste prend les valeurs Docker par défaut : `interval 30s`, `timeout 30s`, `retries 3`. ClickHouse doit donc répondre sur `/ping` en **~2 min 30 au pire**, sinon le conteneur passe `unhealthy`, et comme le service `plausible` a `depends_on: condition: service_healthy`, `docker compose up -d` s'arrête en erreur.

**Pourquoi « ça marchait avant, puis plus jamais ».** C'est le profil de panne le plus cohérent avec la description : le temps de démarrage de ClickHouse croît avec le nombre de parts sur disque et dépend fortement des I/O. Sur un VPS lent dont le volume `event-data` a grossi, on finit par franchir le seuil — de façon définitive, et sans que rien n'ait changé côté configuration.

**Correctif appliqué.** `compose.low-resources.yml` (opt-in) porte les deux bases à `start_period: 5m`, `interval: 10s`, `retries: 30`.

**Diagnostic.** `docker inspect --format '{{json .State.Health}}' plausible-ce-plausible_events_db-1 | jq` et les logs du conteneur.

### P3 — Répartition de la mémoire (4 Go), pas de swap

L'amont recommande 2 Go minimum ; avec **4 Go**, la marge est correcte pour les trois processus lourds (VM Erlang, ClickHouse, Postgres). Le point à surveiller n'est donc pas la quantité totale mais la **répartition** : par défaut ClickHouse s'autorise 90 % de la RAM visible, soit ~3,6 Go, ce qui ne laisse presque rien aux deux autres. `clickhouse/memory-limits.xml` le plafonne à 50 % (2 Go) ; le cache de marques reste aux 500 Mio de l'amont, qui tiennent largement dans cette enveloppe.

Le swap reste recommandé (§6) — 2 Go suffisent — mais c'est ici un filet de sécurité pour le pic de `db migrate`, pas un correctif à un manque chronique.

**Diagnostic :** `dmesg -T | grep -i -E 'oom|killed process'`, `docker inspect --format '{{.State.OOMKilled}}' <conteneur>`. Si aucun OOM n'apparaît, cette piste est close et il faut regarder P2 puis P7.

**Réglage optionnel.** Avec 2 vCPU, le `max_threads: 1` du profil amont est volontairement conservateur ; le passer à 2 dans `clickhouse/default-profile-low-resources-overrides.xml` accélère les requêtes du tableau de bord, au prix d'un pic mémoire un peu plus élevé. À ne faire qu'une fois le déploiement stabilisé, et en gardant à l'esprit que cela crée une divergence avec l'amont.

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

Sur le chemin de déploiement (branche `kamal`) :

- `Dockerfile` — image amont **v3.1.0 → v3.2.1** (correctif de sécurité, P5) ; le `CMD` mal formé — trois chaînes en forme exec, dont seule la première aurait servi d'exécutable — est retiré, la commande venant de toute façon de `servers.web.cmd`.
- `config/deploy.analytics.yml` — ajout du `proxy/healthcheck` sur `/api/health` (K1), de `HTTP_PORT`, `TMPDIR`, `ERL_FLAGS`, du volume `plausible-data`, de la rotation des logs, de l'`ulimit` ClickHouse et des deux nouveaux fichiers de configuration ClickHouse ; retrait de `readiness_delay` (K3), d'`ELIXIR_APPLICATION_ENV` (K4) et de `CLICKHOUSE_PASSWORD` (K9).
- `config/deploy.yml` — conservé tel quel (destination, registre local, `builder/arch`), commentaires ajoutés.
- `.kamal/secrets*` — inchangés (références Dashlane, aucune valeur en clair).
- `clickhouse/default-profile-low-resources-overrides.xml` — **nouveau** (correctif P1).
- `clickhouse/low-resources.xml` — réduit à `mark_cache_size`.
- `clickhouse/memory-limits.xml` — **nouveau**, plafonne ClickHouse à 50 % de la RAM (2 Go sur 4).

Pour l'évaluation locale :

- `compose.yml` — aligné sur l'amont v3.2.1 (ClickHouse 24.12, `CLICKHOUSE_SKIP_USER_SETUP=1`, montage `users.d/`), `ERL_FLAGS` conservé.
- `compose.low-resources.yml` — **nouveau**, surcouche opt-in (healthchecks, mémoire, logs).

Documentation :

- `README.md` — version amont v3.2.1, organisation des branches, procédure Kamal.
- `.gitignore` — refondu : les deux listes blanches (Kamal et ClickHouse) étaient incompatibles après fusion automatique et masquaient `config/deploy.analytics.yml` ainsi que les fichiers `.kamal/secrets*`.

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

# 1. Swap, si absent : filet de sécurité pour le pic de migration et de bascule
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

Le déploiement réel se fait depuis la branche **`kamal`**, avec Kamal 2 et une **destination** : `config/deploy.yml` porte la configuration commune, `config/deploy.analytics.yml` l'instance `analytics.foxtarget.com` (serveur `akira`, utilisateur SSH `deploy`).

Particularité de ce dépôt, et c'est un bon choix : l'image amont n'est pas tirée directement de ghcr.io. Le `Dockerfile` la réétiquette (`FROM ghcr.io/plausible/community-edition:<version>`) et Kamal la pousse via son **registre local** (`localhost:5555`, tunnel SSH). Deux corvées disparaissent du même coup — pas d'identifiants de registre à gérer, pas de `--version` à passer à chaque commande, puisque Kamal étiquette avec le SHA git. En contrepartie, **la version de Plausible se change dans le `Dockerfile`**, pas dans un fichier de configuration.

Les constats P1, P3, P6 à P9 du §3 restent valables. P2 (healthcheck Compose) est remplacé par son équivalent Kamal, K1 ci-dessous.

> [!IMPORTANT]
> Le `Dockerfile` pointait sur **v3.1.0**, qui fait partie des versions vulnérables à l'exécution de code à distance via `/storybook` (CVE-2026-8467, voir P5). L'instance étant exposée publiquement, c'est le changement le plus urgent de cette fusion : le tag passe à **v3.2.1**.

### K1 — Le healthcheck par défaut de kamal-proxy échoue toujours

C'est, de loin, l'explication la plus probable des déploiements qui n'aboutissent pas.

kamal-proxy interroge **`/up`** par défaut, et `config/deploy.analytics.yml` ne définissait aucun `proxy/healthcheck`. Plausible n'expose pas cette route : elle renvoie 404, le proxy ne bascule jamais le trafic, et le déploiement échoue en timeout — quelle que soit la santé réelle de l'application. L'historique de la branche (`5min timeout`, `remove timers`, `no cache warmup`, `try`, `retry`) est cohérent avec cette panne : le symptôme ressemble à une application lente à démarrer, alors que le proxy interroge simplement la mauvaise URL.

Routes réellement exposées :

| Route | Comportement |
| --- | --- |
| `/api/health` | 200 seulement si Postgres **et** ClickHouse **et** les caches **et** les sessions sont prêts |
| `/api/system/health/live` | 200 dès que la VM répond (aucune vérification des bases) |
| `/api/system/health/ready` | identique à `/api/health` |

La configuration utilise désormais `/api/health` : le trafic n'est basculé que sur une instance réellement fonctionnelle. Si un déploiement devait échouer alors que l'application tourne, `/api/system/health/live` est le repli — mais il ne garantit rien sur les bases.

### K2 — `deploy_timeout` : déjà correct

Le conteneur enchaîne `db createdb`, `db migrate` puis `run` : le port ne s'ouvre qu'à la fin. Les 30 s par défaut ne suffisent pas. `deploy_timeout: 600` était déjà en place et a été conservé.

### K3 — `readiness_delay: 600` ne servait à rien

Ce réglage ne s'applique qu'aux conteneurs **qui ne sont pas derrière le proxy et qui ne déclarent pas de healthcheck**. Le rôle `web` étant proxifié, Kamal l'ignore purement et simplement : il n'a jamais rallongé quoi que ce soit. Retiré, pour ne pas laisser croire qu'un délai de 10 minutes est en place.

### K4 — `ELIXIR_APPLICATION_ENV` n'existe pas

La variable `ELIXIR_APPLICATION_ENV: ":plausible, Plausible.Cache, enabled: false"` a été retirée : **aucune occurrence dans le code de Plausible v3.2.1** (vérifié sur l'ensemble du dépôt amont). Elle n'a donc jamais désactivé le cache — Elixir ne dispose d'aucun mécanisme générique de ce genre, et `Plausible.Cache`/`enabled` n'est réglable que par fichier de configuration, à la compilation (c'est ce que fait `config/test.exs`).

C'est une bonne nouvelle : si elle avait fonctionné, elle aurait **définitivement cassé** `/api/health`, qui exige que les caches critiques soient prêts pour renvoyer 200 — et donc rendu tout déploiement impossible via K1.

### K5 — TLS : un seul terminateur

kamal-proxy occupe les ports **80 et 443** et gère Let's Encrypt (`proxy/ssl: true`). Donc :

- **ne pas définir `HTTPS_PORT`** — c'est le seul déclencheur du Let's Encrypt interne de Plausible ; définie, elle ferait démarrer un second serveur ACME en conflit avec le proxy. Sans elle, la redirection HTTPS interne reste désactivée : pas de risque de boucle de redirection ;
- `HTTP_PORT: "8000"` est désormais explicite, en accord avec `proxy/app_port: 8000` (Plausible écoute sur 8000 par défaut, ce qui marchait par coïncidence) ;
- `BASE_URL` reste en `https://…` : c'est lui qui détermine le cookie `secure`.

### K6 — Ne pas activer `forward_headers`

Plausible détermine l'IP du visiteur en prenant la **première** valeur de `X-Forwarded-For`. Avec `ssl: true`, kamal-proxy réécrit cet en-tête avec l'IP réelle du client : c'est le comportement voulu. Activer `forward_headers: true` lui ferait conserver l'en-tête envoyé par le client, qui passerait alors en première position — n'importe quel visiteur pourrait falsifier son IP, donc son pays, dans les statistiques. À laisser désactivé tant que rien d'autre (Cloudflare, un autre proxy) n'est placé devant.

### K7 — Les accessoires ne sont pas gérés par `kamal deploy`

Deux conséquences pratiques :

- **Modifier un fichier `clickhouse/*.xml` n'a aucun effet sur un simple `kamal deploy`.** Les fichiers déclarés sous `files:` sont téléversés au boot de l'accessoire ; il faut `kamal accessory reboot events-db -d analytics`. C'est indispensable pour que le correctif P1 (profil dans `users.d`) prenne effet.
- **Aucun ordonnancement ni healthcheck entre accessoires et application.** Au premier démarrage, l'application peut boucler en redémarrages tant que ClickHouse n'est pas prêt ; `deploy_timeout` laisse le temps que ça se stabilise.

### K8 — Où sont les données

Kamal ne crée pas de volumes docker nommés pour les accessoires : il monte des répertoires du serveur, relatifs au répertoire de connexion SSH — ici l'utilisateur `deploy`, donc `/home/deploy` :

| Donnée | Emplacement sur `akira` |
| --- | --- |
| Postgres | `/home/deploy/plausible-db/db-data` |
| ClickHouse | `/home/deploy/plausible-events-db/event-data` |
| Logs ClickHouse | `/home/deploy/plausible-events-db/event-logs` |
| Config ClickHouse | `/home/deploy/plausible-events-db/etc/clickhouse-server/…` |
| Données Plausible | volume docker `plausible-data` |

Les deux bases publient un port sur la boucle locale (`127.0.0.1:5432`, `127.0.0.1:8123`), ce qui rend les sauvegardes simples depuis le serveur :

```sh
pg_dump -h 127.0.0.1 -U postgres -d plausible_db | gzip > plausible-pg-$(date +%F).sql.gz
```

Sauvegarder **avant** le passage en v3.2.1 : le retour arrière d'une migration Plausible n'est pas supporté.

### K9 — Incohérence sur le mot de passe Postgres

`DATABASE_URL` se connecte avec le mot de passe littéral `postgres`, alors que l'accessoire `db` reçoit un `POSTGRES_PASSWORD` issu de Dashlane. Deux mécanismes de l'image `postgres` expliquent que ça fonctionne quand même — et pourquoi c'est fragile :

- `POSTGRES_PASSWORD` n'est lu qu'à la **première** initialisation du répertoire de données. Ensuite l'entrypoint le voit, constate que la base existe (`PG_VERSION` présent) et l'ignore complètement. Le volume a donc été initialisé avec `postgres`, et le secret Dashlane n'a jamais rien protégé.
- L'entrypoint n'ajoute qu'une seule ligne à `pg_hba.conf` : `host all all all scram-sha-256`. Les connexions par **socket Unix** restent en `trust`, celles par TCP exigent le mot de passe.

**Le vrai risque n'est pas l'accès, c'est la reconstruction.** Aujourd'hui, si le volume était recréé — nouveau serveur, restauration de sauvegarde, `directories` effacé — Postgres s'initialiserait avec le mot de passe **Dashlane** pendant que l'application continuerait à présenter `postgres`. Résultat : une base inaccessible, au pire moment, avec un message d'authentification qui ne dit pas d'où vient le désaccord.

#### Étape 0 — Établir quel mot de passe la base accepte réellement

Le piège : `docker exec … psql -U postgres` passe par le socket Unix, donc par `trust`. **Cette commande réussit quel que soit le mot de passe et ne prouve rien.** Il faut forcer une connexion TCP avec `-h 127.0.0.1` :

```sh
# sur akira
PW=$(dcli read dl://plausible-postgres-password/password)

docker exec -e PGPASSWORD=postgres plausible-db \
  psql -h 127.0.0.1 -U postgres -d plausible_db -c 'select 1'      # (a)
docker exec -e PGPASSWORD="$PW" plausible-db \
  psql -h 127.0.0.1 -U postgres -d plausible_db -c 'select 1'      # (b)
```

| Résultat | Situation | Suite |
| --- | --- | --- |
| (a) passe | la base est bien sur `postgres` | option A ou B ci-dessous |
| (b) passe | la base est déjà sur le secret Dashlane, et l'application ne peut pas se connecter du tout | seule l'étape A3 est nécessaire |
| aucun ne passe | ni l'un ni l'autre — regarder `kamal accessory logs db -d analytics` avant toute chose | — |

#### Option A — Aligner sur le secret Dashlane (recommandé)

**A1. Vérifier que le mot de passe passe sans encodage dans une URL.** Plausible transmet `DATABASE_URL` telle quelle à Ecto, qui décode la partie `user:password` avec `URI.decode_www_form/1`. Un `@`, `:`, `/`, `#`, `?` ou `%` casse l'analyse de l'URL, et un `+` serait décodé en **espace**.

```sh
printf '%s' "$PW" | grep -qE '^[A-Za-z0-9._~-]+$' \
  && echo "utilisable tel quel" \
  || echo "à régénérer en alphanumérique, ou à encoder en pourcentage"
```

Le plus simple est de régénérer un mot de passe sans caractère spécial dans Dashlane : `openssl rand -hex 24`.

**A2. Changer le mot de passe dans Postgres.** Le socket Unix étant en `trust`, l'ancien mot de passe n'est pas nécessaire. Passer l'ordre par l'entrée standard plutôt qu'avec `-c`, pour qu'il n'apparaisse pas dans la table des processus du serveur :

```sh
printf "ALTER USER postgres PASSWORD '%s';\n" "$PW" \
  | docker exec -i plausible-db psql -U postgres -d postgres
```

À ce stade l'application tourne encore avec l'ancien mot de passe en mémoire : elle continue de fonctionner jusqu'à la prochaine reconnexion. Enchaîner sans traîner.

**A3. Basculer `DATABASE_URL` en secret.** Dans `.kamal/secrets.analytics`, **après** la ligne `POSTGRES_PASSWORD` (la substitution est séquentielle) :

```sh
DATABASE_URL=postgres://postgres:$POSTGRES_PASSWORD@plausible-db:5432/plausible_db
```

Et dans `config/deploy.analytics.yml` :

```diff
 env:
   clear:
     ...
-    DATABASE_URL: postgres://postgres:postgres@plausible-db:5432/plausible_db
     CLICKHOUSE_DATABASE_URL: http://plausible-events-db:8123/plausible_events_db
   secret:
     - SECRET_KEY_BASE
+    - DATABASE_URL
```

**A4. Déployer et vérifier :**

```sh
kamal deploy -d analytics
curl -fsS https://analytics.foxtarget.com/api/health   # doit renvoyer postgres: "ok"
```

**Retour arrière**, si A3 échoue alors que A2 est déjà passé : remettre l'ancien mot de passe côté base avec la commande de A2 (`postgres` à la place de `$PW`), puis redéployer la configuration précédente. Ne pas se contenter de rétablir `DATABASE_URL` : la base, elle, a déjà changé.

#### Option B — Assumer le mot de passe par défaut

C'est la posture de l'amont, dont le `compose.yml` utilise `POSTGRES_PASSWORD=postgres`. Il faut alors le rendre **explicite et cohérent**, pour ne pas retomber sur le piège de la reconstruction : retirer `POSTGRES_PASSWORD` de `secret` et le déclarer en clair à `postgres` dans `env/clear` de l'accessoire.

Ce qui est accepté en faisant ce choix : le port n'est publié que sur `127.0.0.1`, mais tout compte du serveur et **tout conteneur du réseau docker `kamal`** — donc toute autre application déployée par Kamal sur `akira` — peut se connecter à la base. Acceptable si la machine n'héberge que Plausible.

#### Dans le même esprit : `CLICKHOUSE_PASSWORD`

Retiré de l'accessoire `events-db`. Avec `CLICKHOUSE_SKIP_USER_SETUP=1`, l'entrypoint de l'image ne configure aucun utilisateur : la variable n'avait aucun effet, et `CLICKHOUSE_DATABASE_URL` ne porte de toute façon pas de mot de passe. Si l'accès à ClickHouse doit être protégé un jour, cela passe par un fichier dans `users.d`, pas par cette variable.


### K10 — Ce que Kamal ajoute en consommation

kamal-proxy est un conteneur Go supplémentaire (empreinte faible) et Kamal conserve l'ancien conteneur applicatif le temps du basculement : pendant un déploiement, **deux instances de Plausible tournent brièvement en parallèle**. C'est le pic de consommation du cycle de vie, et il se cumule avec les migrations. Avec 4 Go et ClickHouse plafonné à 2 Go, ça passe ; c'est la raison principale de garder du swap.

### Aide-mémoire

```sh
kamal deploy -d analytics                        # déploiement
kamal app logs -f -d analytics                   # logs applicatifs
kamal accessory logs events-db -f -d analytics   # logs ClickHouse
kamal accessory reboot events-db -d analytics    # après modification des XML
kamal proxy logs -f -d analytics                 # healthcheck, TLS, routage
kamal app details -d analytics                   # conteneurs et versions en place
kamal rollback <sha> -d analytics                # bascule sur un conteneur encore présent
```


## 8. Points restés ouverts

- La cause exacte de la panne d'origine n'est pas prouvée faute d'accès aux logs du VPS : P2 et P1+P3 sont les hypothèses les plus probables, le §5 permet de trancher en une minute.
- Les valeurs de `compose.low-resources.yml` et `clickhouse/memory-limits.xml` sont calibrées pour **2 vCPU / 4 Go**. À revoir si la machine change : abaisser le ratio à 0,4 sous 2 Go, le remonter vers 0,6–0,7 au-delà de 8 Go.
- La quantité de RAM étant confortable, le facteur limitant probable est le **disque** (débit et place libre), qui n'a pas pu être mesuré d'ici. Les deux hypothèses de tête, P2 et P7, en dépendent directement.
