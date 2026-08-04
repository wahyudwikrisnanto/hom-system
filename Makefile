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

logs-frontend: ## Tail frontend logs
	$(DC) logs -f --tail=100 frontend

sh: ## Shell into the backend container
	$(DC) exec backend bash

sh-frontend: ## Shell into the frontend container
	$(DC) exec frontend bash

yarn: ## Run yarn in the frontend, e.g. make yarn cmd="add foo"
	$(DC) exec frontend yarn $(cmd)

psql: ## Open psql on the local database
	$(DC) exec pgsql psql -U hom -d hom

redis-cli: ## Open redis-cli
	$(DC) exec redis redis-cli

artisan: ## Run artisan, e.g. make artisan cmd="route:list"
	$(DC) exec backend php artisan $(cmd)

migrate: ## Run migrations
	$(DC) exec backend php artisan migrate

# DatabaseSeeder starts with AmpabaSeeder + `ampaba:sync:branch`, which call the partner
# API and fail without credentials. These are the seeders that run offline.
LOCAL_SEEDERS := RoleSeeder PermissionSeeder SettingSeeder BranchSeeder QuestionnaireSeeder \
	UserSeeder BannerSeeder SkillSeeder PersonalTrainerSeeder ClassCategorySeeder \
	InstructorSeeder ClassModelSeeder ToolSeeder MuscleSeeder ExerciseSeeder \
	ClassScheduleSeeder MembershipSeeder ProductSeeder

seed: ## Seed local data (skips the Ampaba seeders, which need partner API access)
	@for s in $(LOCAL_SEEDERS); do \
		echo "==> $$s"; \
		$(DC) exec -T backend php artisan db:seed --force --class=$$s || exit 1; \
	done

# `migrate:fresh` only drops tables in the search_path (config/database.php pins it to
# "public"), so the ampaba schema survives and its create-table migration then fails.
# Drop it explicitly first.
fresh: ## Wipe the database, re-run migrations, then seed
	$(DC) exec -T pgsql psql -U hom -d hom -c 'DROP SCHEMA IF EXISTS ampaba CASCADE'
	$(DC) exec backend php artisan migrate:fresh --force
	@$(MAKE) --no-print-directory seed

composer: ## Run composer, e.g. make composer cmd="require foo/bar"
	$(DC) exec backend composer $(cmd)

test: ## Run the backend test suite
	$(DC) exec backend php artisan test

.PHONY: help init build up up-workers down destroy restart ps logs logs-backend logs-frontend sh sh-frontend yarn psql redis-cli artisan migrate seed fresh composer test
