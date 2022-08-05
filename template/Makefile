start:
	docker compose up -d --build 

down:
	docker compose down 

touchdown:
	touch logs/wordpress-installed

configure:
	docker compose -f docker-compose.yml -f wp-auto-config.yml run --rm wp-auto-config

install: start
	docker compose -f docker-compose.yml -f wp-auto-config.yml run --rm wp-auto-config
	touch logs/wordpress-installed
	
clean: down
	@echo "💥 Removing related folders/files..."
	@rm -rf  mysql/* wordpress/*

reset: clean

