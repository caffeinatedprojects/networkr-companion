start:
	docker compose up -d --build 

down:
	docker compose down 

touchdown:
	@touch logs/wordpress-installed

configure:
	docker compose -f docker-compose.yml -f wp-auto-config.yml run --rm wp-auto-config

install: start
	docker compose -f docker-compose.yml -f wp-auto-config.yml run --rm wp-auto-config
	
clean: 
	@echo "💥 Removing related folders/files..."
	@rm -rf  data/db/ data/site/

reset: clean

siteurl: 
	docker compose run --quiet-pull --rm wpcli option get siteurl