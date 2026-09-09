# The ECS task start command must change to `start-from-setup` when the version is updated
# For new environment creations, the command must be `start-from-init` with the `--steps` flag pointing to the steps.yaml file
FROM ghcr.io/zitadel/zitadel:v4.17.1@sha256:3ac6910685d48f32481f01f45e3e6215efe5a9df2c069591b481e9a101712db5

# Add custom configuration
COPY --chown=zitadel:zitadel ./*.yaml /app/

# Add system user public key
COPY --chown=zitadel:zitadel ./system-user.pub /app/users/system-user.pub
