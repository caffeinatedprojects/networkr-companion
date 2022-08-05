start:
	docker compose up -d --build 

down:
	docker compose down 

configure:
	docker compose -f docker-compose.yml -f wp-auto-config.yml run --rm wp-auto-config

install: start
	docker compose -f docker-compose.yml -f wp-auto-config.yml run --rm wp-auto-config

clean: 
	@echo "💥 Removing related folders/files..."
	@rm -rf  mysql/* wordpress/*
	down

reset: clean

