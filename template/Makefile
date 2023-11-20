include .env

COLOUR_GREEN=\033[0;32m
COLOUR_RED=\033[0;31m
COLOUR_BLUE=\033[0;34m
COLOUR_END=\033[0m

start:
	docker compose up -d --build 

down:
	docker compose down

restart:
	docker compose down
	docker compose up -d --build

wpinfo:
	 docker compose run --rm $(CONTAINER_CLI_NAME) --info

install: 
	docker compose up -d --build 
	docker exec $(CONTAINER_CLI_NAME) wp core install \
	  --path="/var/www/html" \
	  --url="$(PRIMARY_URL)" \
	  --title=$(WP_TITLE) \
	  --admin_user="$(WP_ADMIN_USER)" \
	  --admin_password="$(WP_ADMIN_TEMP_PASS)" \
	  --admin_email="$(WP_ADMIN_MAIL)"
	
clean: 
	@echo "💥 Removing related folders/files..."
	@rm -rf  data/db/* data/site/* data/backup/*

reset: clean

siteurl: 
	docker exec $(CONTAINER_CLI_NAME) wp option get siteurl

setup:
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

# make changedomain domain_old='hidaway.co.uk'
changedomain:
	@echo " Replacing $(COLOUR_RED)$(domain_old)$(COLOUR_END) >>> $(COLOUR_GREEN)$(URL_WITHOUT_HTTP)"$(COLOUR_END)
	docker exec $(CONTAINER_CLI_NAME) wp option update home "$(PRIMARY_URL)" 
	docker exec $(CONTAINER_CLI_NAME) wp option update siteurl "$(PRIMARY_URL)" 
	@echo "$(COLOUR_GREEN) Find Replace Domian $(COLOUR_END)"
	docker exec $(CONTAINER_CLI_NAME) wp search-replace "$(domain_old)" "$(URL_WITHOUT_HTTP)" --skip-columns=guid
	docker compose down
	docker compose up -d --build 

db-import:
	@echo "$(COLOUR_BLUE)Importing MYSQL File: $(MYSQL_DATABASE)$(COLOUR_END)"
	docker exec $(CONTAINER_DB_NAME) \
	  sh -c 'exec mysql -uroot -p"$(MYSQL_ROOT_PASSWORD)" $(MYSQL_DATABASE)' \
	  > data/temp/mysql.sql

db-export:
	@echo "$(COLOUR_BLUE)Exporting Database: $(MYSQL_DATABASE)$(COLOUR_END)"
	@docker exec $(CONTAINER_DB_NAME) \
	  sh -c 'exec mysqldump --databases $(MYSQL_DATABASE) -uroot -p"$(MYSQL_ROOT_PASSWORD)"' \
	  > data/mysql.sql

backup: db-export
	@echo "$(COLOUR_BLUE)Compressing Back Up $(COLOUR_END)"
	@tar -czf backup.tar.gz data/site data/mysql.sql -group=$(COMPOSE_PROJECT_NAME) --owner=$(COMPOSE_PROJECT_NAME)
	@mv backup.tar.gz data/backup/backup-$$(date '+%Y-%m-%d').tar.gz
	@chown $(COMPOSE_PROJECT_NAME):$(COMPOSE_PROJECT_NAME) data/backup/backup-$$(date '+%Y-%m-%d').tar.gz
	@echo "$(COLOUR_BLUE)Tinying Up $(COLOUR_END)"
	@rm -f data/mysql.sql
	@find data/backup/ -type f -mtime +7 -name '*.gz' -execdir rm -- '{}' \;
	@echo "$(COLOUR_GREEN)Backup Successful$(COLOUR_END)"

import: db-import 
	mv data/temp/site/wp-content/* data/site/wp-content/
	rm -rf data/temp/* 

theme-list:
	docker exec $(CONTAINER_CLI_NAME) wp theme list --format=json

# theme-update:
# 	docker exec $(CONTAINER_CLI_NAME) wp theme update --all

# theme-install:
# 	docker exec $(CONTAINER_CLI_NAME) wp theme install $$theme --activate

theme-activate:
	docker exec $(CONTAINER_CLI_NAME) wp theme activate $$theme

theme-delete:
	rm -rf data/site/wp-content/themes/$$theme

theme-disable:
	docker exec $(CONTAINER_CLI_NAME) wp theme disable $$theme  

plugin-list:
	docker exec $(CONTAINER_CLI_NAME) wp plugin list --format=json

# plugin-update:
# 	docker exec $(CONTAINER_CLI_NAME) wp plugin update --all

# plugin-install:
# 	docker exec $(CONTAINER_CLI_NAME) wp plugin install $$plugin --activate

plugin-activate:
	docker exec $(CONTAINER_CLI_NAME) wp plugin activate $$plugin

plugin-delete:
	rm -rf data/site/wp-content/plugins/$$plugin

plugin-disable:
	docker exec $(CONTAINER_CLI_NAME) wp plugin disable $$plugin