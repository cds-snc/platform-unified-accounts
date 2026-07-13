# The ECS task start command must change to `start-from-setup` when the version is updated
# For new environment creations, the command must be `start-from-init` with the `--steps` flag pointing to the steps.yaml file
FROM ghcr.io/zitadel/zitadel:v4.16.0@sha256:15543f7a80c3e37905fe8c7db56af7ed2a9ece256704322c1449d7e8453afdab

# Add custom configuration
COPY --chown=zitadel:zitadel ./*.yaml /app/
