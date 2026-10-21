# The ECS task start command must change to `start-from-setup` when the version is updated
# For new environment creations, the command must be `start-from-init` with the `--steps` flag pointing to the steps.yaml file
FROM ghcr.io/zitadel/zitadel:v4.19.5@sha256:a586456a208e0db4c633db0ba43c427c24b37846138b8b13ff16ad8e003a18d3

# Add custom configuration
COPY --chown=zitadel:zitadel ./*.yaml /app/
