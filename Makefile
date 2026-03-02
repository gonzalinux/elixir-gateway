.PHONY: help install setup run run2 install-certbot deploy logs stop ps

help: ## Show this help message
	@echo "Available targets:"
	@echo "  setup           Install dependencies and setup project"
	@echo "  run             Start the Phoenix server (dev mode)"
	@echo "  install         Install dependencies only"
	@echo "  install-certbot Install certbot for SSL certificate management"
	@echo "  prod          Build and deploy with Docker Compose"
	@echo "  logs            Follow container logs"
	@echo "  stop            Stop Docker containers"
	@echo "  ps              Show container status"

install: ## Install dependencies only
	mix deps.get

setup: ## Install dependencies and setup project
	mix setup

run: ## Start the Phoenix server (loads .env if present)
ifeq ($(OS),Windows_NT)
	script\run_server.bat .env
else
	./script/run_server.sh .env
endif

run2: ## Start the Phoenix server with .env2 configuration
ifeq ($(OS),Windows_NT)
	script\run_server.bat .env2
else
	./script/run_server.sh .env2
endif

prod: ## Build and deploy with Docker Compose (minimal downtime)
	docker compose up -d --build --remove-orphans

logs: ## Follow container logs
	docker compose logs -f

stop: ## Stop Docker containers
	docker compose stop

ps: ## Show container status
	docker compose ps

install-certbot: ## Install certbot for SSL certificate management
	@echo "Installing certbot via snap..."
	@if command -v snap >/dev/null 2>&1; then \
		sudo snap install --classic certbot; \
		sudo ln -sf /snap/bin/certbot /usr/bin/certbot; \
	else \
		echo "Snap not found. Please install snapd first."; \
		exit 1; \
	fi
	@echo "Certbot installed successfully!"
