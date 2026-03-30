FROM ghcr.io/zitadel/zitadel-login:v4.13.0@sha256:b1048d2652988a32518d5e4a26eecea0dd1db0792e144bd9715c7b96fdf3b1fd

USER root

RUN apk update && apk upgrade && rm -rf /var/cache/apk/*

USER nextjs