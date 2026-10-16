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
| 9. Admin panel, events system, external dashboard | Next |
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
- **Reading it:** `TradeLogger.history(userId)`, `TradeLogger.get(key)` and `TradeLogger.recent()` for the admin panel. The record shape is `Shared/TradeLog` (tested).
