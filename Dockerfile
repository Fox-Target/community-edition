# Réétiquetage de l'image amont, pour que Kamal ait quelque chose à « construire »
# et à pousser via son registre local. Rien n'est compilé ici.
#
# v3.2.1 corrige une exécution de code à distance via l'endpoint /storybook
# (CVE-2026-8467), qui touche toutes les versions de v3.0.0-rc.0 à v3.2.0.
FROM ghcr.io/plausible/community-edition:v3.2.1

# La commande de démarrage (createdb + migrate + run) est définie par
# `servers.web.cmd` dans config/deploy.<destination>.yml. Sans surcharge ici,
# c'est l'ENTRYPOINT de l'image amont qui s'applique.
