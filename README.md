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

$ ls -1
AUDIT.md
clickhouse/
compose.low-resources.yml
compose.yml
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
| `config/deploy.yml` + `.kamal/secrets.example` | déploiement avec **Kamal 2** (voir ci-dessous) |
| `ERL_FLAGS=+sbwt none +sbwtdcpu none +sbwtdio none` | désactive l'attente active de la VM Erlang, réduit la conso CPU au repos |
| `compose.low-resources.yml` | surcouche **optionnelle** pour petit VPS : healthchecks tolérants, plafond mémoire ClickHouse, rotation des logs Docker |
| `clickhouse/memory-limits.xml` | plafonne ClickHouse à 50 % de la RAM, pour laisser de la place aux autres services |
| [`AUDIT.md`](AUDIT.md) | audit du déploiement : causes probables d'échec, diagnostic, procédures |

Sur un VPS peu doté, démarrer avec la surcouche :

```console
$ docker compose -f compose.yml -f compose.low-resources.yml up -d
```

### Déploiement avec Kamal

Le déploiement cible est [Kamal 2](https://kamal-deploy.org). Les étapes en quatre points — le détail des pièges est dans [`AUDIT.md` § 7](AUDIT.md).

1. Renseigner les valeurs `CHANGEME` de `config/deploy.yml` : IP du VPS (trois fois), domaine, login GitHub.

2. Créer le fichier de secrets, qui reste hors de git :

    ```console
    $ cp .kamal/secrets.example .kamal/secrets
    $ export KAMAL_REGISTRY_PASSWORD=...   # PAT GitHub, scope read:packages
    $ export SECRET_KEY_BASE=$(openssl rand -base64 48)
    $ export POSTGRES_PASSWORD=$(openssl rand -base64 24)
    ```

3. Première installation — les ports 80 et 443 du VPS doivent être libres :

    ```console
    $ kamal setup -P --version=v3.2.1
    ```

4. Mises à jour ultérieures :

    ```console
    $ kamal deploy -P --version=v3.2.1
    ```

> [!IMPORTANT]
> `-P` et `--version` sont obligatoires : l'image est celle publiée par Plausible, rien n'est construit ici. Sans `--version`, Kamal cherche un tag correspondant au SHA git de ce dépôt, qui n'existe pas sur ghcr.io.

Après modification d'un fichier `clickhouse/*.xml`, un `kamal deploy` ne suffit pas — il faut redémarrer l'accessoire :

```console
$ kamal accessory reboot events-db
```

Le fichier `compose.yml` reste utilisable tel quel, notamment pour évaluer une version en local avant de la déployer.

Pour resynchroniser avec l'amont :

```console
$ git remote add upstream https://github.com/plausible/community-edition
$ git fetch upstream
$ git merge upstream/master
```

### Wiki

For more information on installation, upgrades, configuration, and integrations please see our [wiki.](https://github.com/plausible/community-edition/wiki)

### Contact

- For release announcements please go to [GitHub releases.](https://github.com/plausible/analytics/releases)
- For a question or advice please go to [GitHub discussions.](https://github.com/plausible/analytics/discussions/categories/self-hosted-support)
