<div align="center">
  <img src="frontend/public/amatya-logo.png" alt="Amatya" width="180" />

   Amatya
 Order Book Matching Engine using PostgreSQL
  Indian equities and cryptocurrency, priced in rupees

  A university DBMS project that puts the exchange *inside* the database:
  price-time priority matching, dual-balance settlement, fees and audit
  trail all execute as one PL/pgSQL transaction.

  **Simulation only — no real money.** Balances are demo credits. There
  is no payment gateway, bank rail or live market feed anywhere in it.
What this project is

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


