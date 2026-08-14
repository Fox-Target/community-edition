# Audit du déploiement Plausible CE

Date : 2026-08-14 · Dépôt : `Fox-Target/plausible-community-edition`

## 1. Méthode et limites

Ce qui a pu être vérifié :

- comparaison ligne à ligne du dépôt avec l'amont `plausible/community-edition` (historique complet cloné) ;
- disponibilité réelle des images (`ghcr.io/plausible/community-edition`, `clickhouse/clickhouse-server`, `postgres`) interrogée directement sur les registries ;
- validation des fichiers `compose.yml` / `compose.low-resources.yml` (`docker compose config`) et des XML ClickHouse ;
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

## 7. Points restés ouverts

- La cause exacte de la panne d'origine n'est pas prouvée faute d'accès aux logs du VPS : P2 et P1+P3 sont les hypothèses les plus probables, le §5 permet de trancher en une minute.
- Les valeurs de `compose.low-resources.yml` et `clickhouse/tiny-vps.xml` sont calibrées pour 1–2 Go de RAM ; elles méritent d'être ajustées si le VPS est plus (ou moins) doté.
- Sous ~1 Go de RAM, même après ces correctifs, ClickHouse reste au-dessus de ce que la machine peut absorber confortablement : ajouter du swap est alors un pansement, pas une solution.
