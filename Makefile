DC = docker compose

.PHONY: up test mutation diff psql down

up:
	$(DC) up -d --wait

test: up
	$(DC) exec -T db bash /work/scripts/run-tests.sh

mutation: up
	$(DC) exec -T db bash /work/scripts/mutation.sh

diff:
	$(DC) run --rm go

psql: up
	$(DC) exec db psql -U postgres

down:
	$(DC) --profile diff down -v
