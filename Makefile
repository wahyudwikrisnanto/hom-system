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

dev-be: ## Run the backend natively (php artisan serve on :8000) — stateful services still need `make up`
	cd gym-backend && php artisan serve --port=8000

dev-fe: ## Run the frontend natively (yarn dev on :3000)
	cd gym-frontend && yarn dev

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

logs-minio: ## Tail minio logs
	$(DC) logs -f --tail=100 minio

logs-automation: ## Tail automation (Vite sandbox) logs
	$(DC) logs -f --tail=100 automation

sh: ## Shell into the backend container
	$(DC) exec backend bash

sh-frontend: ## Shell into the frontend container
	$(DC) exec frontend bash

yarn: ## Run yarn in the frontend, e.g. make yarn cmd="add foo"
	$(DC) exec frontend yarn $(cmd)

sh-automation: ## Shell into the automation container
	$(DC) exec automation bash

npm: ## Run npm in automation, e.g. make npm cmd="install foo"
	$(DC) exec automation npm $(cmd)

# The panel has its own base URL, so it is not part of this run — see cypress-panel.
cypress: ## Run the system E2E suites (backend + frontend) and record the run
	$(DC) --profile automation run --rm cypress run --spec "cypress/e2e/{backend,frontend}/**/*.cy.ts" $(cmd)

cypress-frontend: ## Drive the Nuxt admin only (cypress/e2e/frontend)
	$(DC) --profile automation run --rm cypress run --spec "cypress/e2e/frontend/**/*.cy.ts" $(cmd)

cypress-backend: ## Drive the CMS API only (cypress/e2e/backend)
	$(DC) --profile automation run --rm cypress run --spec "cypress/e2e/backend/**/*.cy.ts" $(cmd)

cypress-panel: ## Smoke the control panel itself (automation:5173)
	$(DC) --profile automation run --rm -e CYPRESS_BASE_URL=http://automation:5173 cypress run --spec "cypress/e2e/panel/**/*.cy.ts" $(cmd)

automation-migrate: ## Sync the automation schema and the suite registry
	$(DC) exec automation npm run db:migrate

psql-automation: ## Open psql on the automation panel's database
	$(DC) exec pgsql psql -U hom -d hom_automation

automation-check: ## Format, lint and build the automation repo in its container
	$(DC) exec automation npm run check

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
	ClassScheduleSeeder MembershipSeeder ProductSeeder PaymentMethodSeeder

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

.PHONY: help init build up dev-be dev-fe up-workers down destroy restart ps logs logs-backend logs-frontend logs-minio logs-automation sh sh-frontend sh-automation yarn npm cypress cypress-frontend cypress-backend cypress-panel automation-migrate psql-automation automation-check psql redis-cli artisan migrate seed fresh composer test
