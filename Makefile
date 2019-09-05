SHELL := /bin/bash -O expand_aliases
PHONY :=
.DEFAULT_GOAL := help
.EXPORT_ALL_VARIABLES:
ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
CERT_DIR := $(ROOT_DIR)/data/reverseproxy/etc/nginx/certs
MAKEFILE := $(ROOT_DIR)/Makefile
HELPER_DIR := $(ROOT_DIR)/helper
NETWORK_NAME := dde
DOCKER_BUILDKIT := 1
DDE_UID := $(shell id -u)
DDE_GID := $(shell id -g)



.PHONY: help
help: ## Display this message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'



.PHONY: system-up
system-up: ## Initializes and starts dde system infrastructure
	$(call log,"Creating network if required")
	@docker network create $(NETWORK_NAME) || true

	$(call log,"Creating default docker config.json")
	@if [ ! -f ~/.docker/config.json ]; then \
		mkdir -p ~/.docker && \
		echo '{}' > ~/.docker/config.json; \
	fi

	$(call log,"Creating CA cert if required")
	@mkdir -p $(CERT_DIR)
	@cd $(CERT_DIR) && \
		if [ ! -f ca.pem ]; then \
			openssl genrsa -out ca.key 2048 && \
			openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/C=CH/ST=Bern/L=Bern/O=dde/CN=dde" -out ca.pem; \
		fi

	$(call log,"Creating certs used by system services")
	@$(HELPER_DIR)/generate-vhost-cert.sh $(CERT_DIR) portainer.test;
	@$(HELPER_DIR)/generate-vhost-cert.sh $(CERT_DIR) mailhog.test;

	$(call log,"Starting containers")
	@cd $(ROOT_DIR) && docker-compose up -d

	$(call addSshKey)

	$(call log,"Finished startup successfully")



.PHONY: system-status
system-status: ## Print dde system status
	@cd $(ROOT_DIR) && \
		docker-compose ps



.PHONY: system-start
system-start: ## Start already created system dde environment
	@cd $(ROOT_DIR) && \
		docker-compose start

	$(call addSshKey)



.PHONY: system-stop
system-stop: ## Stop system dde environment
	@cd $(ROOT_DIR) && \
		docker-compose stop



.PHONY: system-update
system-update: ## Update dde system

		$(call log,"Removing dde (system)")
		@make -f $(MAKEFILE) system-destroy

		$(call log,"Updating dde repository")
		@cd $(ROOT_DIR) && git pull

		$(call log,"Updating docker images")
		@cd $(ROOT_DIR) && docker-compose pull && docker-compose build --pull

		$(call log,"Starting dde (system)")
		@make -f $(MAKEFILE) system-up

		$(call log,"Finished update successfully")



.PHONY: system-destroy
system-destroy: ## Remove system dde infrastructure

	$(call log,"Removing containers")
	@docker rm -f $$(docker network inspect -f '{{ range $$key, $$value := .Containers }}{{ printf "%s\n" $$key }}{{ end }}' $(NETWORK_NAME)) &> /dev/null
	@cd $(ROOT_DIR) && docker-compose down -v --remove-orphans

	$(call log,"Removing network if created")
	@if [ "$$(docker network ls | grep $(NETWORK_NAME))" ]; then \
		docker network rm $(NETWORK_NAME) || true; \
	fi

	$(call log,"Finished destroying successfully")



.PHONY: system-nuke
system-nuke: ## Remove system dde infrastructure and nukes data

	$(call log,"Removing dde sytem")
	@make -f $(MAKEFILE) system-destroy

	$(call log,"Removing data")
	@cd $(ROOT_DIR) && sudo find ./data/* -maxdepth 1 -not -name .gitkeep -exec rm -rf {} ';'

	$(call log,"Finished nuking successfully")



.PHONY: system-cleanup
system-cleanup: ## Cleanup whole docker environment. USE WITH CAUTION

	$(call log,"Running docker-gc")
	@docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -e REMOVE_VOLUMES=1 spotify/docker-gc sh -c "/docker-gc || true"

	$(call log,"Shrinking down docker data")
	@docker run --rm -it --privileged --pid=host walkerlee/nsenter -t 1 -m -u -i -n fstrim /var/lib/docker

	$(call log,"Finished system cleanup")



.PHONY: system-log
system-log: ## Show log output of system services
	@cd $(ROOT_DIR) && docker-compose logs -f --tail=100



.PHONY: up
up: ## Creates and starts project containers
	$(call checkProject)

	$(call log,"Generating SSL cert")
	@for vhost in `grep VIRTUAL_HOST= docker-compose.yml | cut -d'=' -f2`; do \
		$(HELPER_DIR)/generate-vhost-cert.sh $(CERT_DIR) $$vhost; \
	done

	$(if $(wildcard ./docker-sync.yml), $(call startDockerSync))

	$(call log,"Starting containers")
	@docker-compose up -d

	$(if $(wildcard ./mutagen.yml),$(call startMutagen))
	$(call log,"Finished startup successfully")



.PHONY: status
status: ## Print project status
	$(call checkProject)
	@docker-compose ps



.PHONY: start
start: ## Start already created project environment
	$(call checkProject)
	$(if $(wildcard ./docker-sync.yml),$(call startDockerSync))
	$(call log,"Starting docker containers")
	@docker-compose start
	$(if $(wildcard ./mutagen.yml),$(call startMutagen))



.PHONY: stop
stop: ## Stop project environment
	$(call checkProject)

	$(call log,"Starting docker containers")
	@docker-compose stop

	$(if $(wildcard ./mutagen.yml),$(call stopMutagen))
	$(if $(wildcard ./docker-sync.yml),$(call startDockerSync))


.PHONY: update
update: ## Update/rebuild project
	$(call checkProject)

	$(call log,"Destroying project")
	@make -f $(MAKEFILE) destroy

	$(call log," Pulling/building images")
	@docker-compose build --pull
	@docker-compose pull

	$(call log,"Starting project")
	@make -f $(MAKEFILE) up

	$(call log,"Finished update successfully")



.PHONY: destroy
destroy: ## Remove central project infrastructure
	$(call checkProject)
	$(call log,"Removing containers")
	@docker-compose down -v --remove-orphans

	$(call log,"Deleting SSL certs")
	@for vhost in `grep VIRTUAL_HOST= docker-compose.yml | cut -d'=' -f2`; do \
		rm -f $(CERT_DIR)/$$vhost.*; \
	done

	$(if $(wildcard ./mutagen.yml),$(call stopMutagen))
	$(if $(wildcard ./docker-sync.yml),$(call startDockerSync))
	$(call cleanup)

	$(call log,"Finished destroying successfully")



.PHONY: exec
exec: ## Opens shell with user dde on first container
	$(call checkProject)
	@docker-compose exec `docker run --rm -v $(CURDIR):/workdir mikefarah/yq yq r docker-compose.yml services | head -n1 | tr -d ':'` gosu dde sh || true



.PHONY: exec_root
exec_root: ## Opens privileged shell on first container
	$(call checkProject)
	@docker-compose exec `docker run --rm -v $(CURDIR):/workdir mikefarah/yq yq r docker-compose.yml services | head -n1 | tr -d ':'` sh || true




.PHONY: log
log: ## Show log output
	@docker-compose logs -f --tail=100

#
# FUNCTIONS
#

define log
	@tput -T xterm setaf 3
	@shopt -s xpg_echo && echo $1
	@tput -T xterm sgr0
endef


define checkProject
	@if [ "$(ROOT_DIR)" == "$(shell pwd)" ]; then \
		echo dde root is not a valid project directory && \
		exit 1; \
	fi
	@if [ ! -f docker-compose.yml ]; then \
		echo docker-compose.yml not found && \
		exit 1; \
	fi

	@mkdir -p .dde
	@cp -R "$(ROOT_DIR)/helper/configure-image.sh" .dde/configure-image.sh
endef


define startDockerSync
    $(if $(shell which docker-sync),$(call log, "docker-sync is installed"), $(call log, "docker-sync is not installed, see: https://docker-sync.io"); exit 1)
	$(call log,"Starting docker-sync. This can take several minutes depending on your project size")

	@if [ -f docker-sync.yml ]; then \
		docker-sync stop && \
		docker-sync start; \
	fi
endef



define stopDockerSync
   $(call log,"Stopping docker-sync");
	docker-sync stop;
endef


define stopMutagen
   $(call log,"Stopping mutagen");
   mutagen project terminate;
endef


define startMutagen
    $(if $(shell which mutagen),$(call log, "mutagen is installed"), $(call log, "mutagen is not installed, see: https://mutagen.io"); exit 1)
	$(call log,"Starting mutagen. This can take several minutes depending on your project size")

	@if ! grep -q "defaultOwner" "./mutagen.yml"; then \
	docker run --rm -e DDE_UID -e DDE_GID -v $(CURDIR):/workdir mikefarah/yq sh -c "yq w -d'*' -i  mutagen.yml 'sync.*.configurationBeta.permissions.defaultOwner' id:${DDE_UID} && yq w -d'*' -i mutagen.yml  'sync.*.configurationBeta.permissions.defaultGroup' id:${DDE_GID}"; \
	fi

	 @-mutagen project terminate &> /dev/null || true
	mutagen project start;
endef


define addSshKey
	$(call log,"Adding SSH key (maybe passphrase required)")
	@cd $(ROOT_DIR) && docker-compose exec ssh-agent sh -c "ssh-add /home/dde/.ssh/id_rsa && ssh-add -l"
endef
