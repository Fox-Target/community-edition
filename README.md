<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/plausible/community-edition/refs/heads/v2.1.1/images/logo_dark.svg" width="300">
        <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/plausible/community-edition/refs/heads/v2.1.1/images/logo_light.svg" width="300">
        <img src="https://raw.githubusercontent.com/plausible/community-edition/refs/heads/v2.1.1/images/logo_light.svg" width="300">
    </picture>
</p>

<p align="center">
    A getting started guide to self-hosting <a href="https://plausible.io/blog/community-edition">Plausible Community Edition</a>
</p>

---

### Prerequisites

- **[Docker](https://docs.docker.com/engine/install/)** and **[Docker Compose](https://docs.docker.com/compose/install/)** must be installed on your machine.
- **CPU** must support **SSE 4.2** or **NEON** instruction set or higher (required by ClickHouse).
- At least **2 GB of RAM** is recommended for running ClickHouse and Plausible without fear of OOMs.

### Quick start

#### 1. Clone this repository

```console
$ git clone https://github.com/Fox-Target/plausible-community-edition plausible-ce
Cloning into 'plausible-ce'...

$ cd plausible-ce

$ git checkout kamal

$ ls -1
AUDIT.md
clickhouse/
compose.low-resources.yml
compose.yml
config/
Dockerfile
LICENSE
README.md
```

#### 2. Create and configure your [environment](https://docs.docker.com/compose/environment-variables/) file

```console
$ touch .env
$ echo "BASE_URL=https://plausible.example.com" >> .env
$ echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" >> .env

$ cat .env
BASE_URL=https://plausible.example.com
SECRET_KEY_BASE=...unique secret key base...
```

Make sure `$BASE_URL` is set to the **actual domain** where you plan to host the service. The domain must have a DNS entry pointing to your server for proper resolution and automatic Let's Encrypt TLS certificate issuance. More on that in the next step.

Also ensure `$SECRET_KEY_BASE` is set to at least a **64-byte** string.

> [!TIP]
> To evaluate CE locally, set `BASE_URL=http://localhost:8000` (or any other port on your system).

#### 3. Expose Plausible server to the web with a [compose override file:](https://github.com/plausible/community-edition/wiki/compose-override)

```sh
$ echo "HTTP_PORT=80" >> .env
$ echo "HTTPS_PORT=443" >> .env

$ cat > compose.override.yml << EOF
services:
    plausible:
        ports:
            - 80:80
            - 443:443
EOF
```

Setting `HTTP_PORT=80` and `HTTPS_PORT=443` enables automatic Let's Encrypt TLS certificate issuance. You might want to choose different values if, for example, you plan to run Plausible behind [a reverse proxy.](https://github.com/plausible/community-edition/wiki/reverse-proxy)

> [!TIP]
> To evaluate CE locally, you only need to set `HTTP_PORT` and expose it on the system port from the previous step, e.g. for `BASE_URL=http://localhost:8000` and server `HTTP_PORT=80`, `ports` override should be `- 8000:80`.

#### 4. Start the services with Docker Compose:

```console
$ docker compose up -d
```

#### 5. Visit your instance at `$BASE_URL` and create the first user.

> [!NOTE]
> Plausible CE is funded by our cloud subscribers.
>
> If you know someone who might [find Plausible useful](https://plausible.io/?utm_medium=Social&utm_source=GitHub&utm_campaign=readme), we'd appreciate if you'd let them know.

### Notes de ce fork

Ce dépôt suit [plausible/community-edition](https://github.com/plausible/community-edition) (actuellement **v3.2.1**) avec quelques ajouts :

| Ajout | Rôle |
| --- | --- |
| `Dockerfile`, `config/deploy*.yml`, `.kamal/secrets*` | déploiement avec **Kamal 2** (voir ci-dessous) |
| `ERL_FLAGS=+sbwt none +sbwtdcpu none +sbwtdio none` | désactive l'attente active de la VM Erlang, réduit la conso CPU au repos |
| `clickhouse/default-profile-low-resources-overrides.xml` | correctif amont : sans lui, les réglages « low resources » sont ignorés |
| `clickhouse/memory-limits.xml` | plafonne ClickHouse à 50 % de la RAM, pour laisser de la place aux autres services |
| `compose.low-resources.yml` | surcouche **optionnelle** pour l'évaluation locale : healthchecks tolérants, rotation des logs |
| [`AUDIT.md`](AUDIT.md) | audit du déploiement : causes probables d'échec, diagnostic, procédures |

### Organisation des branches

Ce dépôt est un fork de [plausible/community-edition](https://github.com/plausible/community-edition), où **chaque version amont est une branche**. Le flux est le suivant :

1. synchroniser le fork avec l'amont (les branches `v3.2.1`, `v3.1.0`, …) ;
2. fusionner la branche de version voulue dans **`kamal`** ;
3. `kamal` est la branche déployée — c'est la seule qui porte le `Dockerfile`, `config/deploy*.yml` et les secrets.

Toute modification liée au déploiement va donc dans `kamal`, pas dans la branche par défaut.

### Déploiement avec Kamal

Le déploiement utilise [Kamal 2](https://kamal-deploy.org) avec une **destination** (`require_destination: true`) : la configuration commune est dans `config/deploy.yml`, celle de l'instance dans `config/deploy.analytics.yml`.

```console
$ kamal deploy -d analytics
```

L'image amont n'est pas tirée directement : le `Dockerfile` la réétiquette et Kamal la pousse par son **registre local** (`localhost:5555`, tunnel SSH vers le serveur). C'est ce qui évite d'avoir à gérer des identifiants de registre et à passer `--version` à chaque déploiement. Changer de version de Plausible = changer le tag dans le `Dockerfile`.

Les secrets sont lus depuis Dashlane via `dcli` au moment du déploiement (`.kamal/secrets.analytics`) : aucune valeur en clair n'est stockée dans le dépôt.

> [!IMPORTANT]
> Après modification d'un fichier `clickhouse/*.xml`, un `kamal deploy` ne suffit pas : les accessoires ne sont pas retouchés par un déploiement. Il faut `kamal accessory reboot events-db -d analytics`.

Commandes utiles :

```console
$ kamal app logs -f -d analytics             # logs applicatifs
$ kamal accessory logs events-db -f -d analytics
$ kamal proxy logs -f -d analytics           # échecs de healthcheck, TLS, routage
$ kamal app details -d analytics             # conteneurs et versions en place
```

Le détail des pièges rencontrés est dans [`AUDIT.md` § 7](AUDIT.md).

### Évaluation locale

`compose.yml` reste utilisable tel quel pour essayer une version avant de la déployer, éventuellement avec la surcouche petite configuration :

```console
$ docker compose -f compose.yml -f compose.low-resources.yml up -d
```

### Resynchroniser avec l'amont

```console
$ git remote add upstream https://github.com/plausible/community-edition
$ git fetch upstream
$ git checkout kamal
$ git merge v3.2.1        # branche de version déjà synchronisée depuis l'amont
```

### Wiki

For more information on installation, upgrades, configuration, and integrations please see our [wiki.](https://github.com/plausible/community-edition/wiki)

### Contact

- For release announcements please go to [GitHub releases.](https://github.com/plausible/analytics/releases)
- For a question or advice please go to [GitHub discussions.](https://github.com/plausible/analytics/discussions/categories/self-hosted-support)
