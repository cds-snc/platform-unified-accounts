.PHONY: cert docker-idp docker-idp-login run

cert:
	openssl \
		req \
		-nodes \
		-newkey rsa:2048 \
		-x509 -days 3650 \
		-keyout ./docker/idp/private.key \
		-out ./docker/idp/certificate.crt \
		-subj "/C=CA/ST=Ontario/L=Ottawa/O=cds-snc/OU=platform/CN=accounts.cdssandbox.xyz/emailAddress=platform-core-services@cds-snc.ca" > /dev/null 2>&1
	chmod +r ./docker/idp/private.key

docker-idp: cert
	docker build \
		-t idp:latest \
		-f ./docker/idp/Dockerfile ./docker/idp

docker-idp-login:
	docker build \
		-t idp-login:latest \
		-f ./docker/idp-login/Dockerfile ./docker/idp-login

run: cert
	docker-compose -f ./docker/docker-compose.yml up