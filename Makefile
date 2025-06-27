.PHONY: help install setup run install-certbot

help: ## Show this help message
	@echo "Available targets:"
	@echo "  setup           Install dependencies and setup project"
	@echo "  run             Start the Phoenix server"
	@echo "  install         Install dependencies only"
	@echo "  install-certbot Install certbot for SSL certificate management"

install: ## Install dependencies only
	mix deps.get

setup: ## Install dependencies and setup project
	mix setup

run: ## Start the Phoenix server
	mix phx.server

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