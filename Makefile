.PHONY: up down logs smoke clean

up:
	docker compose up --build -d --wait

down:
	docker compose down

logs:
	docker compose logs -f

smoke:
	./scripts/smoke.sh

# Removes containers, networks and named volumes.
clean:
	docker compose down -v --remove-orphans
