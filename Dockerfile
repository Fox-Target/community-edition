FROM ghcr.io/plausible/community-edition:v3.1.0
CMD ["./entrypoint.sh db createdb", "./entrypoint.sh db migrate", "./entrypoint.sh run"]

# HEALTHCHECK --interval=10s --timeout=3s CMD wget -q --spider http://localhost:8000 || exit 1
