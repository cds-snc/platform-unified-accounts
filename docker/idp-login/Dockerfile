FROM ghcr.io/zitadel/zitadel-login:v4.15.3@sha256:906081d8c5b8760321fa811d670e680247f768e5c4bdd4edb73d3ea942800385

USER root

RUN apk update && apk upgrade && rm -rf /var/cache/apk/*

USER nextjs