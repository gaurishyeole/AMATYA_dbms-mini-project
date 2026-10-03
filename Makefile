# Amatya — one-line commands for the lab machine.
PSQL ?= psql
DB   ?= amatya
DBURL ?= postgresql://amatya:amatya@localhost:5432/$(DB)

.PHONY: help db-up db-reset db-verify api web test explain

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/ →/'

db-up:            ## start PostgreSQL 16 in Docker
	docker compose up -d db

db-reset:         ## drop, recreate and reseed the database
	$(PSQL) "$(DBURL:$(DB)=postgres)" -c "DROP DATABASE IF EXISTS $(DB);" -c "CREATE DATABASE $(DB);"
	$(PSQL) "$(DBURL)" -v ON_ERROR_STOP=1 -f db/01_schema.sql
	$(PSQL) "$(DBURL)" -v ON_ERROR_STOP=1 -f db/02_functions.sql
	$(PSQL) "$(DBURL)" -v ON_ERROR_STOP=1 -f db/03_seed.sql
	$(PSQL) "$(DBURL)" -c "ANALYZE;"

db-verify:        ## prove the money invariant and show the book
	$(PSQL) "$(DBURL)" -c "SELECT * FROM check_money_invariant();" \
	                   -c "SELECT symbol, best_bid, best_ask, last_price FROM mv_market_ticker;" \
	                   -c "SELECT * FROM get_order_book('RELIANCE/INR', 5);"

explain:          ## show the matching engine's access path
	$(PSQL) "$(DBURL)" -c "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders \
	  WHERE pair_id=1 AND side='SELL' AND type='LIMIT' \
	  AND status IN ('OPEN','PARTIALLY_FILLED') \
	  ORDER BY price ASC, created_at ASC, order_id ASC LIMIT 1;"

api:              ## run the FastAPI backend
	cd backend && uvicorn app.main:app --reload --port 8000

web:              ## run the Next.js frontend
	cd frontend && npm run dev

test:             ## run the integration suite against the seeded database
	cd backend && pytest -q
