# The ECS task start command must change to `start-from-setup` when the version is updated
# For new environment creations, the command must be `start-from-init` with the `--steps` flag pointing to the steps.yaml file
FROM ghcr.io/zitadel/zitadel:v4.20.0@sha256:4b318c01580f3782c35c7fac30715b41ec66993a11494662b26a8a8c357cedc6

# Add custom configuration
COPY --chown=zitadel:zitadel ./*.yaml /app/
