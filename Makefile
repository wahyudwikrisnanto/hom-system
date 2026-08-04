UID := $(shell id -u)
GID := $(shell id -g)
export UID
export GID

DC := docker compose

.DEFAULT_GOAL := help

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## Init/update git submodules
	git submodule update --init --recursive

build: ## Build images
	$(DC) build

up: ## Start the local stack
	$(DC) up -d

up-workers: ## Start the stack including queue + scheduler
	$(DC) --profile workers up -d

down: ## Stop the stack
	$(DC) down

destroy: ## Stop the stack and drop volumes (db data is lost)
	$(DC) down -v

restart: down up ## Restart the stack

ps: ## Show container status
	$(DC) ps

logs: ## Tail logs of all services
	$(DC) logs -f --tail=100

logs-backend: ## Tail backend logs
	$(DC) logs -f --tail=100 backend

sh: ## Shell into the backend container
	$(DC) exec backend bash

psql: ## Open psql on the local database
	$(DC) exec pgsql psql -U hom -d hom

redis-cli: ## Open redis-cli
	$(DC) exec redis redis-cli

artisan: ## Run artisan, e.g. make artisan cmd="route:list"
	$(DC) exec backend php artisan $(cmd)

migrate: ## Run migrations
	$(DC) exec backend php artisan migrate

fresh: ## Wipe and re-run migrations with seeders
	$(DC) exec backend php artisan migrate:fresh --seed

composer: ## Run composer, e.g. make composer cmd="require foo/bar"
	$(DC) exec backend composer $(cmd)

test: ## Run the backend test suite
	$(DC) exec backend php artisan test

.PHONY: help init build up up-workers down destroy restart ps logs logs-backend sh psql redis-cli artisan migrate fresh composer test
