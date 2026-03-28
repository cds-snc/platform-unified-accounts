.PHONY: docker-idp docker-idp-login run

docker-idp:
	docker build \
		-t idp:latest \
		-f ./docker/idp/Dockerfile ./docker/idp

docker-idp-login:
	docker build \
		-t idp-login:latest \
		-f ./docker/idp-login/Dockerfile ./docker/idp-login

run:
	docker-compose -f ./docker/docker-compose.yml up