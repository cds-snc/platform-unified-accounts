FROM ghcr.io/zitadel/zitadel:v4.13.0@sha256:fbbe11f3ec190d7147e5e3d650f5d9aaeba822b1e6dcb63d9b946166c32b7c83

# Add custom configuration and certificates
COPY --chown=zitadel:zitadel ./*.yaml ./certificate.crt ./private.key /app/
