FROM ghcr.io/plausible/community-edition:v3.0.1
HEALTHCHECK --interval=10s --timeout=3s CMD wget -q --spider http://localhost:8000 || exit 1
