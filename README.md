<div align="center">
  <img src="frontend/public/amatya-logo.png" alt="Amatya" width="180" />

  # Amatya
  ### Order Book Matching Engine using PostgreSQL
  #### Indian equities and cryptocurrency, priced in rupees

  A university DBMS project that puts the exchange *inside* the database:
  price-time priority matching, dual-balance settlement, fees and audit
  trail all execute as one PL/pgSQL transaction.

  **Simulation only — no real money.** Balances are demo credits. There
  is no payment gateway, bank rail or live market feed anywhere in it.
</div>

---

## What this project is

Most "exchange" projects match orders in application code and use the database as
a place to write the result. That design cannot state what happens when two
buyers hit the same resting order at the same instant, and it usually leaks money
the first time a process dies mid-trade.

Amatya inverts it. `place_order()` is a PL/pgSQL function: it locks the market,
walks the book in price-time order, moves base and quote between four balance
rows, charges maker and taker fees, writes the trade and updates both orders —
and then either all of it commits or none of it does. The FastAPI service binds
parameters and maps error codes; it does not decide anything about trading.

That choice is what makes the project a *database* project, and it is what every
design note below comes back to.

---

## DBMS concepts on display

| Concept | Where to look |
|---|---|
| Normalisation to BCNF, with two documented denormalisations | `docs/ER_DIAGRAM.md` §1 |
| ENUM types, CHECK constraints, composite candidate keys | `db/01_schema.sql` §1–8 |
| Partial + composite indexes matched to the hot query | `db/01_schema.sql` "Matching-engine access path" |
| Stored procedures (PL/pgSQL) | `db/02_functions.sql` — `place_order`, `cancel_order` |
| Triggers: `updated_at`, state-machine guard, append-only log, audit | `db/01_schema.sql` §9 |
| Transactions and ACID | this file, "Why the engine is a transaction" |
| Concurrency control: advisory locks, `FOR UPDATE`, `SKIP LOCKED` | this file, "Concurrency" |
| Views and materialized views | `v_order_book_levels`, `v_portfolio`, `mv_market_ticker` |
| Window functions | `get_order_book()` cumulative depth |
| Set-returning functions, `date_bin()` bucketing | `get_candles()` |
| Referential integrity and cascade policy | every FK in `db/01_schema.sql` |
| Query planning and index verification | `make explain` |

---

## Running it

### 1. Database

```bash
docker compose up -d db          # PostgreSQL 16, seeds itself on first start
```

Or against a local server:

```bash
createdb amatya
psql -d amatya -f db/01_schema.sql
psql -d amatya -f db/02_functions.sql
psql -d amatya -f db/03_seed.sql
psql -d amatya -c "ANALYZE;"     # do not skip: see "Indexing" below
```

The seed builds six markets, five accounts, a few hundred historical trades
spread over six hours and a 20-level book on each side of every market. Every
row of it is produced by calling the real `place_order()`.

| Market | Instrument | Tick | Lot |
|---|---|---|---|
| `RELIANCE/INR` | Reliance Industries | ₹0.05 | 1 share |
| `TCS/INR` | Tata Consultancy Services | ₹0.05 | 1 share |
| `INFY/INR` | Infosys | ₹0.05 | 1 share |
| `HDFCBANK/INR` | HDFC Bank | ₹0.05 | 1 share |
| `BTC/INR` | Bitcoin | ₹1 | 0.0001 |
| `ETH/INR` | Ethereum | ₹0.50 | 0.001 |

Equities and coins run on the same engine with no branching anywhere in the
matching code. The only difference between a share and a coin is three numbers
in `trading_pairs`: shares tick in 5 paise and cannot be split, coins tick
coarser and divide finely. That the schema needed no change to list both is the
clearest evidence it was normalised properly.

### 2. Backend

```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env             # set DATABASE_URL and JWT_SECRET
alembic upgrade head             # optional: same DDL as the .sql files
uvicorn app.main:app --reload
```

OpenAPI docs at <http://localhost:8000/docs>.

### 3. Frontend

```bash
cd frontend
npm install
cp .env.local.example .env.local
npm run dev                      # http://localhost:3000
```

### Demo accounts

Password for all of them: `Password@123`

| Account | Role |
|---|---|
| `alice` | market maker, quotes the bid side |
| `bob` | market maker, quotes the ask side |
| `carol` | taker, has resting orders to cancel |
| `admin` | operator: statistics, solvency check, force-cancel |
| `amatya_treasury` | `SYSTEM` account that receives fees (not a login) |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Next.js 15 · TypeScript · Tailwind · shadcn-style components    │
│  Order book · candles · ticket · blotter · portfolio            │
└───────────────────────────┬──────────────────────────────────────┘
                            │ REST + JWT
┌───────────────────────────▼──────────────────────────────────────┐
│  FastAPI · Pydantic v2 · SQLAlchemy 2.0 async · asyncpg          │
│  Auth, validation, pagination, SQLSTATE → HTTP, retry on deadlock│
└───────────────────────────┬──────────────────────────────────────┘
                            │ SELECT place_order(...)
┌───────────────────────────▼──────────────────────────────────────┐
│  PostgreSQL 16                                                   │
│  ── matching engine (PL/pgSQL)  ── triggers  ── partial indexes  │
│  ── dual-balance ledger         ── views     ── audit log        │
└──────────────────────────────────────────────────────────────────┘
```

The API layer contains no trading rule. Tick size, lot size, minimum notional,
sufficient balance, self-trade prevention and time-in-force are all checked by
the database, so a second client — psql, a script, a load generator — obeys
exactly the same rules as the web app.

---

## The matching engine

### Price-time priority

Resting orders are ranked by price first (highest bid, lowest ask), then by
arrival time, then by `order_id` as a deterministic tiebreak. An incoming
*taker* order walks that queue and fills against it until it runs out of
quantity or the next price is no longer acceptable.

Executions always happen at the **maker's** price. The resting order named the
price and waited; the taker chose to cross the spread. A buy limit at 65,700
that lifts an ask at 65,646 pays 65,646 and gets the difference back
immediately — the engine calls `unlock_funds()` for the price improvement inside
the same fill.

### A worked partial fill

Book: asks of 0.02 BTC at ₹58,72,151 and 0.03 BTC at ₹58,72,651, both from
`bob`. `carol` sends a limit buy, 0.03 BTC at ₹58,73,000, GTC. Taker fee
0.20 %, maker fee 0.10 %.

| Step | What the engine does |
|---|---|
| Reserve | `lock_funds(carol, INR, 0.03 × 58,73,000 = 1,76,190.00)` |
| Fill 1 | 0.02 at ₹58,72,151 = ₹1,17,443.02. Carol's reservation spends that and releases 1,17,460.00 − 1,17,443.02 = ₹16.98 as price improvement — she named a higher price than she had to pay. Carol receives 0.02 − 0.00004 fee = 0.01996 BTC. Bob delivers 0.02 BTC from his lock and receives 1,17,443.02 − 117.44302 = ₹1,17,325.57698. Bob's order → `FILLED`. |
| Fill 2 | 0.01 at ₹58,72,651 = ₹58,726.51 against the second ask, leaving it `PARTIALLY_FILLED` with 0.02 remaining. |
| Close | Carol's order is `FILLED`; `quote_filled` gives an average price of ₹58,72,317.67; leftover reservation released; two rows appended to `trades`; four balance rows and two order rows updated; audit rows written by trigger. |

All of that is one transaction. A crash at any point leaves the book exactly as
it was.

### Time in force

| TIF | Behaviour | Resulting status |
|---|---|---|
| `GTC` | rests on the book until filled or cancelled | `OPEN` / `PARTIALLY_FILLED` |
| `IOC` | fills what it can now, remainder cancelled | `FILLED` or `EXPIRED` |
| `FOK` | fills entirely in one pass or does nothing | `FILLED` or `EXPIRED` |

`FOK` is decided *before* any money moves: the engine sums the available depth at
acceptable prices, excluding the trader's own orders, and if it falls short it
records the order as `EXPIRED` with a reason and returns. Nothing is ever locked
and unlocked for an order that was never going to fill.

`MARKET` orders have no price and cannot rest, so a `GTC` market order is
coerced to `IOC`. They also carry no reservation: instead of locking an
estimated worst case, each fill is capped by what the account can actually pay,
floored to a whole lot. Running out of funds ends the order rather than aborting
it — the fills already made are real and must survive.

### Self-trade prevention

Trading with yourself paints the tape and costs nothing, so it is blocked. The
policy here is **expire-maker**: when the best opposite order belongs to the
taker, that resting order is cancelled (funds released, status `EXPIRED`, an
`STP_EXPIRE_MAKER` row written to the audit log) and matching continues deeper
into the book. The taker still gets genuine liquidity, and the check constraint
`maker_user_id <> taker_user_id` on `trades` means a self-trade cannot be
written even by accident.

The alternative policies — expire-taker, expire-both, decrement-and-cancel —
are one `IF` branch away; expire-maker was chosen because it keeps the incoming
order alive, which is what a trader who mis-clicked would want.

### Fees

Each side pays in the asset it receives: a buyer pays fees in base, a seller in
quote. Fees are **moved to the treasury account**, never destroyed. That is what
makes the conservation check meaningful:

```sql
SELECT * FROM check_money_invariant();
```

The totals per asset must be identical before and after any amount of trading.
If a number moves, the engine leaked money.

---

## Why the engine is a transaction

A single fill touches six or more rows: two orders, four balance rows, one trade,
plus audit rows. Half of that state is meaningless.

| ACID property | How it is obtained |
|---|---|
| **Atomicity** | The whole match runs in one server-side function, so it is one transaction by construction. There is no window in which the buyer has been debited and the seller not credited. |
| **Consistency** | Non-negative CHECKs on `available` and `locked`, `filled_quantity <= quantity`, `maker_user_id <> taker_user_id`, the state-machine trigger, and foreign keys. The engine is written to satisfy them; the constraints are there for when it is wrong. |
| **Isolation** | A per-market advisory lock serialises writers on a book; `SELECT … FOR UPDATE` protects every row that is read and then written. |
| **Durability** | Ordinary WAL. The commit that returns the order id is the commit that persisted the trade. |

Everything runs at `READ COMMITTED`. `SERIALIZABLE` would give the same guarantee
by aborting and retrying conflicting transactions instead, which on a hot market
means most orders fail and are replayed. Explicit locking gives the same
correctness with far less wasted work — the classic trade-off between optimistic
and pessimistic concurrency control, decided here in favour of pessimistic
because contention on a single order book is not rare, it is the normal case.

---

## Concurrency

Two mechanisms, chosen for different jobs.

**1. A per-market mutex.** `pg_advisory_xact_lock(42, pair_id)` is taken by both
`place_order()` and `cancel_order()`. Only one transaction mutates a given book
at a time, while other markets run fully in parallel. The lock is transaction
scoped, so it is released on commit *or* rollback and can never leak. This is
what makes price-time priority provable rather than probable: without it, two
takers could interleave and the second could trade through a better resting
price that the first had already passed.

**2. Row locks.** Each maker order is taken with `SELECT … FOR UPDATE`, as is
every balance row before it is modified. This protects against everything
outside the engine: a cancel, an admin force-cancel, a deposit.

### Why not `SKIP LOCKED` in the matching loop

`FOR UPDATE SKIP LOCKED` is the right tool for a work queue, where any item will
do. An order book is not a work queue — its items are *ranked*. Skipping a
locked best-price order and filling the next one down is, by definition, trading
through a better price: a correctness bug, not a performance win.

So the engine uses a strict `FOR UPDATE` and gets its throughput from the
per-market lock instead. `SKIP LOCKED` does appear in this project, in the one
place where it fits: `sweep_stale_orders()`, a housekeeping batch where order
does not matter and an order currently being matched should simply be left for
the next run.

### Deadlocks

A transaction that trades on two markets can grab balance rows in an order that
conflicts with another transaction. PostgreSQL detects the cycle and aborts one
of them with SQLSTATE `40P01`. Because the whole match is a single transaction,
that rollback is clean — nothing was written — so the API replays it, with
exponential backoff and jitter so two victims do not retry in lockstep
(`backend/app/services/trading.py`). Only `40001` and `40P01` are retried; every
other error is a real rejection and is surfaced immediately.

### Measured

24 shell processes placing market buys against the same BTC/INR book at once:

```
trades before : 229          errors      : 0
trades after  : 253          negative balances : 0
```

Exactly 24 fills, no lost updates, no double-spend, and
`check_money_invariant()` unchanged to the last of ten decimal places.

---

## Indexing

The engine's hot query is "best resting order on the opposite side of market P".
Two partial indexes mirror it exactly:

```sql
CREATE INDEX idx_orders_book_bids ON orders (pair_id, price DESC, created_at ASC, order_id ASC)
    WHERE side = 'BUY'  AND type = 'LIMIT' AND status IN ('OPEN','PARTIALLY_FILLED');
CREATE INDEX idx_orders_book_asks ON orders (pair_id, price ASC,  created_at ASC, order_id ASC)
    WHERE side = 'SELL' AND type = 'LIMIT' AND status IN ('OPEN','PARTIALLY_FILLED');
```

Two properties matter. The `WHERE` clause keeps only live orders in the index —
a few thousand rows instead of every order ever placed. And the column order *is*
the price-time sort, so the planner can satisfy `ORDER BY … LIMIT 1` by walking
the index and stopping at the first entry:

```
Limit
  ->  LockRows
        ->  Index Scan using idx_orders_book_asks on orders
              Index Cond: (pair_id = 1)
```

No sort node, no full scan. Run `make explain` to reproduce it.

One caveat worth knowing for the viva: **run `ANALYZE` after seeding.** With no
statistics the planner underestimates the table and picks a different index with
a sort on top. The index is right either way; the planner needs the numbers to
see it.

Supporting indexes cover the other access patterns: `idx_orders_user_history`
for the paginated blotter, `idx_orders_open_by_user` for the open-orders panel,
`idx_trades_pair_time` for the tape and candles, and one unique index on
`mv_market_ticker(pair_id)` — which exists only because
`REFRESH MATERIALIZED VIEW CONCURRENTLY` requires it, and concurrent refresh is
what keeps readers from blocking on a refresh.

---

## Triggers

| Trigger | Table | What it guarantees |
|---|---|---|
| `trg_*_updated_at` | users, assets, pairs, balances | `updated_at` is always truthful, whoever wrote the row |
| `trg_orders_guard` | orders | terminal states are final; `filled_quantity` never decreases; `status = FILLED` implies fully filled; `closed_at` is stamped automatically |
| `trg_trades_no_update` | trades | the execution log is append-only — UPDATE and DELETE are rejected |
| `trg_orders_audit` | orders | every insert and status change is recorded with before/after images |
| `trg_balances_audit` | balances | every material money movement is recorded |

These are the rules that survive a careless `UPDATE` in psql, which is exactly
why they belong in the database and not in a service class.

A note on `fn_audit_row()`: PL/pgSQL resolves record field references at plan
time, so the trigger selects the entity id with `IF`/`ELSIF` on `TG_TABLE_NAME`
rather than a `CASE` expression over `NEW.<column>` — the untaken branch of a
`CASE` would still be compiled and would fail on a table without that column.
Finding that took one confusing seed run and is now a comment in the file.

---

## API

Base path `/api/v1`. Full OpenAPI at `/docs`.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/register` | — | create an account, credit demo balances |
| POST | `/auth/login` | — | JWT (also `/auth/token` for the Swagger form) |
| GET | `/auth/me` | user | current account |
| GET | `/market/assets`, `/market/pairs` | — | listings, with logo URLs |
| GET | `/market/orderbook?symbol=&depth=` | — | aggregated book with cumulative depth |
| GET | `/market/trades?symbol=&limit=` | — | public tape |
| GET | `/market/tickers` | — | 24 h stats from the materialized view |
| GET | `/market/candles?symbol=&interval=&limit=` | — | OHLCV built from the trade log |
| POST | `/orders` | user | place LIMIT/MARKET with GTC/IOC/FOK |
| DELETE | `/orders/{id}` | user | cancel and release the reservation |
| GET | `/orders?status=&open_only=&symbol=&limit=&offset=` | user | paginated history |
| GET | `/orders/{id}` | user | order with its fills |
| GET | `/account/balances`, `/account/portfolio` | user | ledger and rupee valuation |
| GET | `/account/trades?symbol=&limit=&offset=` | user | personal fills, maker and taker |
| GET | `/admin/stats` | admin | volumes, counts, fees collected |
| GET | `/admin/solvency` | admin | the money conservation check |
| POST | `/admin/orders/{id}/cancel` | admin | force-cancel |
| POST | `/admin/market-stats/refresh` | admin | refresh the ticker view |
| GET | `/admin/audit?entity=&entity_id=` | admin | audit trail |

Engine errors carry a SQLSTATE that the API maps to a status code and a sentence
a trader can act on:

| SQLSTATE | HTTP | Example |
|---|---|---|
| `45001` | 400 | *This order needs 99.0000000000 BTC but only 5.0000000000 is available.* |
| `45002` | 400 | *Price 1476.62 is not a multiple of the RELIANCE/INR tick size 0.05.* |
| `45003` | 409 | *Order 657 is already cancelled and cannot be cancelled.* |
| `45004` | 400 | *There is no market called DOGE/INR.* |
| `45006` | 404 | *No order 1 on this account.* |

**Money is sent as decimal strings, never JSON numbers.** Every JSON number in a
browser is an IEEE-754 double; a quantity like `0.1` would arrive corrupted.
Strings carry the exact `NUMERIC` the database computed all the way to the
screen, and the frontend formats for display without ever re-parsing a value it
is about to send back.

---

## Frontend

Next.js 15 App Router, TypeScript, Tailwind, shadcn-style components, TradingView
Lightweight Charts, lucide-react. Pure dark theme in the specified palette,
declared once as CSS variables in `app/globals.css`.

* **Order book** — the signature element. Each row carries a depth bar sized by
  *cumulative* volume up to that price, so the shape answers "how far will my
  order walk before it fills?" at a glance. Clicking a level loads that price
  into the ticket. The touch line between the sides is a gold rule showing mid
  price and spread, drawn from the seal in the logo.
* **Numbers** are set in JetBrains Mono with tabular figures throughout, because
  a price ladder is only readable when the digits line up.
* **Order ticket** mirrors the market's rules — tick size, lot size, fee preview,
  percentage-of-balance shortcuts — but never decides anything; the database
  re-checks everything and its answer is final.
* **Asset logos** come from `assets.logo_url` and fall back to a tinted monogram,
  so a blocked CDN or a newly listed coin never leaves a broken image.
* Polling pauses while the tab is hidden and an in-flight request is never
  overtaken by the next tick, so stale data can't paint over fresh data. Real
  WebSocket feeds are explicitly out of scope.

---

## Testing

```bash
cd backend && pytest -q      # 11 passed
```

The suite runs against the live seeded database, because the thing under test
*is* the database — mocking it would test nothing. It covers: the book is sorted
and never crossed; a limit order reserves and refunds exactly; a marketable
order fills at the maker's price; IOC expires its remainder instead of resting;
FOK fills completely or not at all; tick, lot, size and notional rules are
enforced; self-trade prevention expires the resting side; cancelling twice is a
409; admin endpoints reject traders and anonymous callers; and twenty concurrent
takers leave the per-asset totals untouched.

There is also a psql script of engine-level checks in the commit history style
of `make db-verify`, and `check_money_invariant()` can be run at any moment.

---

## Deliberately out of scope

Real-time WebSocket market data, microsecond-scale optimisation, stop /
take-profit / iceberg orders, KYC and 2FA, and horizontal scaling. The
single-writer-per-market design here is a correctness choice, and scaling it out
would mean sharding by market and introducing a sequencer — a different project.

Known limits worth saying out loud: fees on an equity buy are charged in the
share itself, so a fee can leave a fractional share balance — correct
arithmetic, slightly odd semantics for an instrument that cannot be split, and
a real exchange would charge brokerage in rupees instead; the treasury account
is identified by role rather than by configuration; candle history in the seed is backdated with the
immutability trigger temporarily disabled (marked clearly, seed only); and the
frontend polls rather than subscribes, so the book can be up to 1.5 s stale.

---

## File map

```
amatya/
├── db/
│   ├── 01_schema.sql        tables, ENUMs, constraints, indexes, triggers, views
│   ├── 02_functions.sql     balance primitives + the matching engine
│   └── 03_seed.sql          assets, markets, accounts, price history, live book
├── backend/
│   ├── app/
│   │   ├── main.py          FastAPI app, CORS, error handling
│   │   ├── core/            settings, bcrypt + JWT, SQLSTATE → HTTP mapping
│   │   ├── db/session.py    async engine and session factory
│   │   ├── models/          SQLAlchemy 2.0 models mirroring the schema
│   │   ├── schemas/         Pydantic v2 request/response models
│   │   ├── services/        engine calls, retry policy, market data reads
│   │   └── api/v1/          auth · market · orders · account · admin
│   ├── alembic/             migration that applies db/*.sql
│   └── tests/test_matching.py
├── frontend/
│   ├── app/                 layout · terminal · login · portfolio
│   ├── components/trade/    book, chart, ticket, blotter, market rail, logos
│   ├── components/ui/       shadcn-style primitives
│   └── lib/                 API client, auth context, polling hook, formatting
├── docs/ER_DIAGRAM.md       textual model, Mermaid ER + state diagrams
├── docker-compose.yml
└── Makefile                 db-reset · db-verify · explain · api · web · test
```

---

<div align="center">
  <sub>Built for a database systems laboratory. The interesting code is in
  <code>db/02_functions.sql</code>.</sub>
</div>
