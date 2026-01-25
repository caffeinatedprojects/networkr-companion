# Central Makefile for managing per-site Docker WordPress stacks
# Lives at: /home/networkr/networkr-companion/Makefile
# Usage examples:
#   sudo make SITE_ROOT=/home/user-site-123 SITE_USER=user-site-123 start
#   sudo make SITE_ROOT=/home/user-site-123 SITE_USER=user-site-123 changedomain domain_old=old.com new_domain=new.com

SHELL := /bin/bash

SITE_ROOT ?= /home/user-site-123
SITE_USER ?= user-site-123

ENV_FILE := $(SITE_ROOT)/.env

# Proxy stack (optional). If compose file missing, we fall back to container restarts.
PROXY_ROOT ?= /home/networkr/networkr-companion/proxy
PROXY_COMPOSE ?= $(PROXY_ROOT)/docker-compose.yml

COLOUR_GREEN=\033[0;32m
COLOUR_RED=\033[0;31m
COLOUR_BLUE=\033[0;34m
COLOUR_YELLOW=\033[0;33m
COLOUR_END=\033[0m

# Load .env and export all keys into the Make environment
ifneq ("$(wildcard $(ENV_FILE))","")
include $(ENV_FILE)
export $(shell sed -n 's/^\([^#][^=]*\)=.*/\1/p' $(ENV_FILE))
endif

dc = cd $(SITE_ROOT) && docker compose

.PHONY: start down restart wpinfo install clean reset siteurl setup config-list \
        env-set env-update-domains \
        proxy-restart \
        changedomain db-import db-export backup import legacy-import \
        theme-list theme-activate theme-delete plugin-list plugin-activate plugin-delete

start:
	@echo "$(COLOUR_BLUE)Starting site at $(SITE_ROOT)...$(COLOUR_END)"
	$(dc) up -d --build

down:
	@echo "$(COLOUR_BLUE)Stopping site at $(SITE_ROOT)...$(COLOUR_END)"
	$(dc) down

restart:
	@echo "$(COLOUR_BLUE)Restarting site at $(SITE_ROOT)...$(COLOUR_END)"
	$(dc) down
	$(dc) up -d --build

wpinfo:
	$(dc) run --rm $(CONTAINER_CLI_NAME) --info

install:
	@echo "$(COLOUR_BLUE)Bringing containers up and installing WordPress...$(COLOUR_END)"
	$(dc) up -d --build
	docker exec $(CONTAINER_CLI_NAME) wp core install \
		--path="/var/www/html" \
		--url="$(PRIMARY_URL)" \
		--title=$(WP_TITLE) \
		--admin_user="$(WP_ADMIN_USER)" \
		--admin_password="$(WP_ADMIN_TEMP_PASS)" \
		--admin_email="$(WP_ADMIN_MAIL)"

clean:
	@echo "💥 Removing related folders/files under $(SITE_ROOT)/data..."
	@rm -rf $(SITE_ROOT)/data/db/* $(SITE_ROOT)/data/site/* $(SITE_ROOT)/data/backup/*

reset: clean

siteurl:
	docker exec $(CONTAINER_CLI_NAME) wp option get siteurl

setup:
	@echo "$(COLOUR_BLUE)Running WP core install and permalinks setup...$(COLOUR_END)"
	docker exec $(CONTAINER_CLI_NAME) wp core install \
		--path="/var/www/html" \
		--url="$(PRIMARY_URL)" \
		--title=$(WP_TITLE) \
		--admin_user="$(WP_ADMIN_USER)" \
		--admin_password="$(WP_ADMIN_TEMP_PASS)" \
		--admin_email="$(WP_ADMIN_MAIL)"
	docker exec $(CONTAINER_CLI_NAME) wp rewrite structure $(WP_PERMA_STRUCTURE)

config-list:
	docker exec $(CONTAINER_CLI_NAME) wp config list

# ----------------------------------------------------------------------
# Proxy helpers
# ----------------------------------------------------------------------
proxy-restart:
	@echo "$(COLOUR_BLUE)Restarting central proxy stack...$(COLOUR_END)"
	@if [ -f "$(PROXY_COMPOSE)" ]; then \
		cd "$(PROXY_ROOT)" && docker compose down && docker compose up -d; \
		echo "$(COLOUR_GREEN)Proxy restarted via docker compose at $(PROXY_ROOT)$(COLOUR_END)"; \
	else \
		echo "$(COLOUR_YELLOW)Proxy compose not found at $(PROXY_COMPOSE). Falling back to container restarts if present...$(COLOUR_END)"; \
		if docker ps --format '{{.Names}}' | grep -q '^nginx-proxy$$'; then docker restart nginx-proxy; fi; \
		if docker ps --format '{{.Names}}' | grep -q '^nginx-proxy-acme$$'; then docker restart nginx-proxy-acme; fi; \
		if docker ps --format '{{.Names}}' | grep -q '^nginx-proxy-automation$$'; then docker restart nginx-proxy-automation; fi; \
		echo "$(COLOUR_GREEN)Proxy restart fallback complete$(COLOUR_END)"; \
	fi

# ----------------------------------------------------------------------
# ENV helpers
# ----------------------------------------------------------------------
env-set:
	@if [ -z "$(key)" ] || [ -z "$(value)" ]; then \
		echo "$(COLOUR_RED)Usage: make env-set SITE_ROOT=... key=KEY value=VALUE$(COLOUR_END)"; \
		exit 1; \
	fi
	@mkdir -p $(SITE_ROOT)
	@if [ ! -f "$(ENV_FILE)" ]; then \
		touch "$(ENV_FILE)"; \
	fi
	@if grep -qE '^$(key)=' "$(ENV_FILE)"; then \
		sed -i "s|^$(key)=.*|$(key)=$(value)|" "$(ENV_FILE)"; \
	else \
		echo "$(key)=$(value)" >> "$(ENV_FILE)"; \
	fi

env-update-domains:
	@if [ -z "$(new_domain)" ]; then \
		echo "$(COLOUR_RED)Usage: make env-update-domains SITE_ROOT=... new_domain=example.com domains=\"example.com,www.example.com\" [letsencrypt_email=\"me@example.com\"]$(COLOUR_END)"; \
		exit 1; \
	fi
	@if [ -z "$(domains)" ]; then \
		domains="$(new_domain),www.$(new_domain)"; \
	fi
	@echo "$(COLOUR_BLUE)Updating $(ENV_FILE) domain keys...$(COLOUR_END)"
	@$(MAKE) env-set SITE_ROOT="$(SITE_ROOT)" key=PRIMARY_DOMAIN value="$(new_domain)"
	@$(MAKE) env-set SITE_ROOT="$(SITE_ROOT)" key=PRIMARY_URL value="https://$(new_domain)"
	@$(MAKE) env-set SITE_ROOT="$(SITE_ROOT)" key=URL_WITHOUT_HTTP value="$(new_domain)"
	@$(MAKE) env-set SITE_ROOT="$(SITE_ROOT)" key=DOMAINS value="$(domains)"
	@if [ -n "$(letsencrypt_email)" ]; then \
		$(MAKE) env-set SITE_ROOT="$(SITE_ROOT)" key=LETSENCRYPT_EMAIL value="$(letsencrypt_email)"; \
	fi
	@echo "$(COLOUR_GREEN).env updated$(COLOUR_END)"

# ----------------------------------------------------------------------
# Domain change
# ----------------------------------------------------------------------
# Important:
# - Does NOT modify permalinks
# - Waits for DB readiness before running wp-cli
# - Runs robust search-replace patterns (https://www, https://, bare)
changedomain:
	@if [ -z "$(domain_old)" ]; then \
		echo "$(COLOUR_RED)Usage: make changedomain SITE_ROOT=... domain_old=old-domain.com$(COLOUR_END)"; \
		exit 1; \
	fi
	@if [ -n "$(new_domain)" ]; then \
		$(MAKE) env-update-domains SITE_ROOT="$(SITE_ROOT)" new_domain="$(new_domain)" domains="$(domains)" letsencrypt_email="$(letsencrypt_email)"; \
	fi

	@echo "Replacing $(COLOUR_RED)$(domain_old)$(COLOUR_END) >>> $(COLOUR_GREEN)$(URL_WITHOUT_HTTP)$(COLOUR_END)"
	$(dc) up -d --build

	@echo "$(COLOUR_BLUE)Waiting for DB to be ready...$(COLOUR_END)"
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
		docker exec $(CONTAINER_CLI_NAME) wp db check --quiet >/dev/null 2>&1 && break; \
		echo "DB not ready yet (try $$i/15)"; \
		sleep 2; \
	done; \
	docker exec $(CONTAINER_CLI_NAME) wp db check --quiet >/dev/null 2>&1 || (echo "$(COLOUR_RED)DB never became ready$(COLOUR_END)"; exit 1)

	docker exec $(CONTAINER_CLI_NAME) wp option update home "$(PRIMARY_URL)"
	docker exec $(CONTAINER_CLI_NAME) wp option update siteurl "$(PRIMARY_URL)"

	@echo "$(COLOUR_GREEN)Running search/replace on database...$(COLOUR_END)"
	@OLD="$(domain_old)"; NEW="$(URL_WITHOUT_HTTP)"; \
	docker exec $(CONTAINER_CLI_NAME) wp search-replace "https://www.$$OLD" "https://www.$$NEW" --all-tables --precise --recurse-objects --skip-columns=guid; \
	docker exec $(CONTAINER_CLI_NAME) wp search-replace "https://$$OLD" "https://$$NEW" --all-tables --precise --recurse-objects --skip-columns=guid; \
	docker exec $(CONTAINER_CLI_NAME) wp search-replace "$$OLD" "$$NEW" --all-tables --precise --recurse-objects --skip-columns=guid

	$(dc) down
	$(dc) up -d --build

	@echo "$(COLOUR_BLUE)Restarting proxy to trigger SSL issuance...$(COLOUR_END)"
	@$(MAKE) proxy-restart

	@echo "$(COLOUR_GREEN)changedomain complete$(COLOUR_END)"

db-export:
	@echo "$(COLOUR_BLUE)Exporting database $(MYSQL_DATABASE)...$(COLOUR_END)"
	@rm -rf $(SITE_ROOT)/data/temp/*
	@mkdir -p $(SITE_ROOT)/data/temp
	docker exec $(CONTAINER_DB_NAME) \
		sh -c 'exec mysqldump --databases "$$MYSQL_DATABASE" -u"root" -p"$$MYSQL_ROOT_PASSWORD"' \
		> $(SITE_ROOT)/data/temp/mysql.sql
	@echo "$(COLOUR_GREEN)Backup saved to 'data/temp/mysql.sql'$(COLOUR_END)"

db-import:
	@echo "$(COLOUR_BLUE)Importing database from data/temp/mysql.sql...$(COLOUR_END)"
	docker exec -i $(CONTAINER_DB_NAME) \
		sh -c 'exec mysql -u"root" -p"$$MYSQL_ROOT_PASSWORD" "$$MYSQL_DATABASE"' \
		< $(SITE_ROOT)/data/temp/mysql.sql
	@echo "$(COLOUR_GREEN)Database import complete.$(COLOUR_END)"

backup: db-export
	@echo "$(COLOUR_BLUE)Preparing wp-content for backup...$(COLOUR_END)"
	@mkdir -p $(SITE_ROOT)/data/temp/wp-content
	@cp -a $(SITE_ROOT)/data/site/wp-content/. $(SITE_ROOT)/data/temp/wp-content/ || true
	@echo "$(COLOUR_BLUE)Compressing backup...$(COLOUR_END)"
	@tar -czvf $(SITE_ROOT)/data/backup/backup.tar.gz -C $(SITE_ROOT)/data/temp . >/dev/null
	@mv $(SITE_ROOT)/data/backup/backup.tar.gz $(SITE_ROOT)/data/backup/backup-$$(date '+%Y-%m-%d').tar.gz
	@chown $(SITE_USER):pressadmin $(SITE_ROOT)/data/backup/backup-$$(date '+%Y-%m-%d').tar.gz
	@echo "$(COLOUR_BLUE)Tidying up temp files...$(COLOUR_END)"
	@rm -rf $(SITE_ROOT)/data/temp/*
	@find $(SITE_ROOT)/data/backup/ -type f -mtime +7 -name '*.gz' -execdir rm -- '{}' \;
	@echo "$(COLOUR_GREEN)Backup successful.$(COLOUR_END)"

import: db-import
	@echo "$(COLOUR_BLUE)Restoring wp-content from data/temp/wp-content...$(COLOUR_END)"
	@cp -a $(SITE_ROOT)/data/temp/wp-content/. $(SITE_ROOT)/data/site/wp-content/ || true
	@rm -rf $(SITE_ROOT)/data/temp/*
	@echo "$(COLOUR_GREEN)Import complete.$(COLOUR_END)"

legacy-import:
	@if [ -z "$(BACKUP)" ]; then \
		echo "$(COLOUR_RED)Usage: make legacy-import BACKUP=path/to/backup.zip$(COLOUR_END)"; \
		exit 1; \
	fi
	@echo "$(COLOUR_BLUE)Restoring from legacy backup: $(BACKUP)$(COLOUR_END)"
	@mkdir -p $(SITE_ROOT)/data/temp
	@unzip -q "$(BACKUP)" -d $(SITE_ROOT)/data/temp/
	@if [ -d "$(SITE_ROOT)/data/temp/public_html/wp-content" ]; then \
		echo "$(COLOUR_BLUE)Restoring wp-content from public_html...$(COLOUR_END)"; \
		cp -a $(SITE_ROOT)/data/temp/public_html/wp-content/. $(SITE_ROOT)/data/site/wp-content/; \
	fi
	@if [ -f "$(SITE_ROOT)/data/temp/mysql.sql" ]; then \
		echo "$(COLOUR_BLUE)Restoring database from mysql.sql...$(COLOUR_END)"; \
		docker exec -i $(CONTAINER_DB_NAME) sh -c 'exec mysql -u"root" -p"$$MYSQL_ROOT_PASSWORD" "$$MYSQL_DATABASE"' < $(SITE_ROOT)/data/temp/mysql.sql; \
	fi
	@rm -rf $(SITE_ROOT)/data/temp/*
	@echo "$(COLOUR_GREEN)Legacy import complete.$(COLOUR_END)"

theme-list:
	docker exec $(CONTAINER_CLI_NAME) wp theme list --format=json

theme-activate:
	@if [ -z "$(theme)" ]; then \
		echo "$(COLOUR_RED)Usage: make theme-activate theme=theme-slug$(COLOUR_END)"; \
		exit 1; \
	fi
	docker exec $(CONTAINER_CLI_NAME) wp theme activate $(theme)

theme-delete:
	@if [ -z "$(theme)" ]; then \
		echo "$(COLOUR_RED)Usage: make theme-delete theme=theme-slug$(COLOUR_END)"; \
		exit 1; \
	fi
	docker exec $(CONTAINER_CLI_NAME) wp theme delete $(theme)

plugin-list:
	docker exec $(CONTAINER_CLI_NAME) wp plugin list --format=json

plugin-activate:
	@if [ -z "$(plugin)" ]; then \
		echo "$(COLOUR_RED)Usage: make plugin-activate plugin=plugin-slug$(COLOUR_END)"; \
		exit 1; \
	fi
	docker exec $(CONTAINER_CLI_NAME) wp plugin activate $(plugin)

plugin-delete:
	@if [ -z "$(plugin)" ]; then \
		echo "$(COLOUR_RED)Usage: make plugin-delete plugin=plugin-slug$(COLOUR_END)"; \
		exit 1; \
	fi
	docker exec $(CONTAINER_CLI_NAME) wp plugin delete $(plugin)