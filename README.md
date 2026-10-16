# Pet Part Hunter

Roblox game: hunt pet parts while a mythic creature chases you, escape with your haul, and build mix-and-match pets.

See [docs/GAME_DESIGN_SPEC.md](docs/GAME_DESIGN_SPEC.md) for the full design specification.

## Status (build order, spec section 10)

| Step | State |
| --- | --- |
| 1. Chase prototype (Common area, chaser, bag, escape) | Done |
| 2. Data layer and validation (profile, session lock, rate-limited remotes, analytics) | Done |
| 3. Speed pads, levels, rebirth | Done (Apex comes after launch tuning) |
| 4. Part pipeline: part table, inventory, merge, pet building, Part Index, crafting UI | Done for all 48 placeholder species (shared pet rig, meshes and animations come with the art pipeline) |
| 5. All six areas, chaser scaling, gamepass and rebirth gating | Done (area mazes, 48 species, per-area chaser speed, free route + pass early access; pass IDs in Config.Passes are 0 until you create the passes) |
| 6. Home building (plot, starter room, furniture shop, placement ghost, move/rotate/delete, visitors, pets wandering) | Done |
| 7. Economy: selling parts, bag upgrades, pet slots, passes, Robux products (coin packs, luck boost, insurance), receipt handling, purchase announcements, everyone sees everyone's pets | Done (pass and product IDs in Config are 0 until you create them on Roblox) |
| 8. Trading: two-sided window (lock, countdown, confirm), eligibility, cooldown, lopsided warning, atomic swap, backend trade log | Done |
| 9. Admin panel, events system, monitoring and anti-exploit, dashboard feed | Done |
| 10. Closed test on phones, tune from the monitoring data, launch | Next (needs real devices and players) |
## Running

- Pure-logic tests: `python tests/run_tests.py` (set `LUAU` and `LUAU_ANALYZE` to the luau tool paths if they are not on PATH).
- In Studio: `rojo serve`, then connect from the Rojo plugin. Studio has no DataStore access by default, so players get temporary,
  unsaved data (`DataPersistent` attribute is false). Enable API access in Game Settings to test saving.
- Studio playtest helpers: set the `DebugChaserSpeed` workspace attribute, or `player:SetAttribute("DebugAddCoins", n)` to test pad buying. Building a pet costs coins and selling parts arrives with the economy step, so use DebugAddCoins to try it. Also `player:SetAttribute("DebugGrantPass", "Area_Mythic")` unlocks a paid area, and `player:SetAttribute("DebugAddCoins", n)` adds coins (needed for the furniture shop until selling exists).
- Where things live: `src/Shared` is pure rules (tested), `src/Server` and `src/Client` connect them to Roblox.

## Trade log (backend)

Every trade window that ends is recorded: completed, cancelled, expired and failed. See `src/Server/TradeLogger.lua`.

- **DataStore** `Config.Backend.TradeStore`: one record per trade under `T<epoch>_<id>`, plus a per-player index `P<userId>` (their most recent trades).
  A completed trade is written **before** the items move. If the record cannot be saved the trade does not happen (Studio excepted).
- **Your own backend (optional):** set `Config.Backend.TradeLogUrl`, enable HttpService, and store the API key as a Roblox secret named `Config.Backend.SecretName`.
  Records are POSTed as JSON with retries in the background.
- **Server output:** one summary line per trade, a warning when flagged (`lopsided`, `volume_<userId>`).
- **Crash recovery (automatic):** a trade moves items between two profiles that are saved separately, so each profile carries a journal
  (`Shared/TradeRecovery`). Order: mark the trade pending in both and save, write the record (the commit point), swap, mark applied and save.
  When a profile loads with a pending trade the server reads the record: none, or a later `_f` record = the trade never happened, so the note
  is dropped; a completed record = the trade happened, so that player's side is applied now (if not already). It is idempotent, each player
  recovers independently, and the tests simulate a crash at every step. Until it is settled the player cannot start another trade.
- **Reading it:** `TradeLogger.history(userId)`, `TradeLogger.get(key)` and `TradeLogger.recent()` for the admin panel. The record shape is `Shared/TradeLog` (tested).

## Events, admin tools and monitoring (build step 9)

**Events** are data, not code (`Shared/Events`, `Server/EventStore`, `Server/EventService`). An admin creates one in the panel (presets for the spec's event types, or
paste a JSON record); it is validated, stored in a DataStore and picked up by every server (refresh timer plus MessagingService). One record can carry modifiers
(luck, coins, speed gain, chaser speed), exclusive parts, a whole event area (a new maze with its own chaser, built while the event runs), a community goal, or a
chaos effect. Event parts are registered before any profile loads and stay registered after the event ends, so saved event parts are never lost; events that have
exclusive parts can be stopped but not deleted. Event parts are non-tradable unless the event says otherwise.

**Admin** (`Shared/Admin`, `Server/AdminService`): set `Config.Admin.Owners / Admins / Mods` (user ids) and/or `GroupId` with `GroupRanks`. In Studio the tester is an owner
(`StudioIsOwner`, never on live servers). Every command is checked on the server (role, validated arguments, a written reason for destructive actions), is written to the
audit log **before** it runs (no record, no action), and denied attempts are logged. Players, coins and parts, kick/ban (reaches all servers), snapshots and rollback,
live tuning (chaser speed, respawn rate, trade switch, per-area chaser and open/closed), events, announcements, metrics and exploit flags. Inventory commands need the target online.
Rolling back keeps trade journals, purchase receipts and passes; anything else earned after the snapshot is undone (the audit log shows what).

**Monitoring and anti-exploit** (`Shared/Metrics`, `Shared/ExploitCheck`, `Server/MetricsService`, `Server/AntiExploit`, `Server/Alerts`):
- Every `Analytics.log` also feeds the counters. Once a minute a snapshot is posted to `Config.Backend.MetricsUrl` as JSON
  `{ v, t, job, seconds, events = { "RunEscaped|area=Rare" = { n, sum }, ... }, gauges = { players, perArea, fps, budgets, uptime } }`.
  Chart in Grafana or similar: catch vs escape per area, `CoinsEarned` vs `CoinsSpent`, purchases, rebirths, session length (`SessionSeconds` sum / count), DataStore errors.
- Exploit checks: impossible speed and teleports, hauls over bag capacity or huge, duplicated item ids, unusual trade volume. They log (DataStore list per day, plus the
  admin panel) and alert; they never kick on their own. Serious ones, or repeats, go to `Config.Backend.AlertUrl` (point it at a small relay; Discord often blocks Roblox).
- Set the API key as a Roblox secret named `Config.Backend.SecretName`. With no URLs set, nothing leaves the server and the in-game numbers still work.
