# The ECS task start command must change to `start-from-setup` when the version is updated
# For new environment creations, the command must be `start-from-init` with the `--steps` flag pointing to the steps.yaml file
FROM ghcr.io/zitadel/zitadel:v4.15.0@sha256:cc9fb3b2788dcbd0dff93781a0323bbe491a4cec11e1caefd9a1ed31f7fdc145

# Add custom configuration
COPY --chown=zitadel:zitadel ./*.yaml /app/
