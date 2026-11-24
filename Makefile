DC = docker compose

.PHONY: up test mutation psql down

up:
	$(DC) up -d --wait

test: up
	$(DC) exec -T db bash /work/scripts/run-tests.sh

mutation: up
	$(DC) exec -T db bash /work/scripts/mutation.sh

psql: up
	$(DC) exec db psql -U postgres

down:
	$(DC) down -v
