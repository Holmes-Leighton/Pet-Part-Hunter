--!strict
-- Crash tests for trading: kill the "server" at every point of a trade and check that, after the profiles are loaded
-- again and recovered, every item exists exactly once and each player ends up with the right side of the trade.
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Parts = require("../src/Shared/Parts")
local Crafting = require("../src/Shared/Crafting")
local Profile = require("../src/Shared/Profile")
local Trade = require("../src/Shared/Trade")
local TradeLog = require("../src/Shared/TradeLog")
local Recovery = require("../src/Shared/TradeRecovery")
local Config = require("../src/Shared/Config")

local A, B = 101, 202

local function fresh(): Profile.Data
	local d = Profile.load(nil, Config)
	d.coins = 100000
	return d
end

local function give(d: Profile.Data, id: string, seed: number): Crafting.Item
	return Crafting.addPart(Config, d, Parts.get(id) :: Parts.Def, Rng.new(seed), 1000)
end

-- What "saving to the DataStore" and loading back does to a profile.
local function saved(d: Profile.Data): Profile.Data
	return Profile.load(d, Config)
end

-- A comparable description of everything tradable a profile holds: parts and pets, ignoring uids.
local function holdings(d: Profile.Data): { string }
	local out: { string } = {}
	for _, it in d.parts do
		table.insert(out, string.format("part %s t%d %.2f/%.2f/%.2f/%.2f", it.id, it.tier, it.stats.speed, it.stats.bag, it.stats.coin, it.stats.luck))
	end
	for _, pet in d.pets do
		local bits = {}
		for socket, it in pet.slots do
			table.insert(bits, socket .. "=" .. it.id .. "/t" .. it.tier .. "/" .. string.format("%.2f", it.stats.speed + it.stats.luck + it.stats.coin + it.stats.bag))
		end
		table.sort(bits)
		table.insert(out, "pet " .. table.concat(bits, ","))
	end
	table.sort(out)
	return out
end

local function everything(a: Profile.Data, b: Profile.Data): { string }
	local out = holdings(a)
	for _, s in holdings(b) do
		table.insert(out, s)
	end
	table.sort(out)
	return out
end

type Scenario = {
	a0: Profile.Data, -- both profiles as saved before the trade
	b0: Profile.Data,
	a1: Profile.Data, -- saved with the pending note, before the swap
	b1: Profile.Data,
	a2: Profile.Data, -- saved after the swap and settle
	b2: Profile.Data,
	record: TradeLog.Record,
	expectA: { string }, -- what each player should end with
	expectB: { string },
	key: string,
}

-- Runs a whole trade, snapshotting what would be on disk at each stage. Mirrors TradeService.complete.
local function scenario(): Scenario
	local da, db = fresh(), fresh()
	local head = give(da, "Chicken_Head", 1)
	local legs = give(da, "Tiger_Legs", 2)
	local rare = give(da, "Kraken_Body", 3)
	rare.tier = 2
	local pet = Crafting.buildPet(Config, da, { Head = head.uid, Legs = legs.uid }) :: Crafting.Pet
	local x = give(db, "Fox_Tail", 4)
	local y = give(db, "Owl_Head", 5)
	local a0, b0 = saved(da), saved(db)
	local expectA, expectB = holdings(b0), holdings(a0) -- everything swaps (both offered everything)

	local s = Trade.new(Config, "trade-1", { userId = A, name = "Ana" }, { userId = B, name = "Ben" }, 0)
	local datas: { [number]: any } = { [A] = da, [B] = db }
	assert(Trade.setOffer(Config, s, A, da :: any, { rare.uid }, { pet.uid }, 1))
	assert(Trade.setOffer(Config, s, B, db :: any, { x.uid, y.uid }, {}, 1))
	Trade.lock(s, A, 1)
	Trade.lock(s, B, 1)
	local later = 1 + Config.Trade.ConfirmDelay
	local ev = Trade.evaluate(Config, s, datas)
	assert(Trade.confirm(Config, s, A, true, ev, later))
	assert(Trade.confirm(Config, s, B, true, ev, later))

	-- Step 1: pending note in both, saved.
	local preview = table.clone(s)
	preview.state, preview.reason = "completed", "completed"
	local gave = { [A] = Trade.gave(s, A, da :: any), [B] = Trade.gave(s, B, db :: any) }
	local record = TradeLog.build(preview, gave, ev, 100, 160, "job", nil)
	local key = TradeLog.key(record)
	Recovery.begin(da :: any, s.id, key)
	Recovery.begin(db :: any, s.id, key)
	local a1, b1 = saved(da), saved(db)

	-- Step 2 is the log write (the record). Step 3: swap, settle, save.
	assert(Trade.execute(Config, s, datas, later + 1))
	Recovery.settle(da :: any, s.id)
	Recovery.settle(db :: any, s.id)
	return { a0 = a0, b0 = b0, a1 = a1, b1 = b1, a2 = saved(da), b2 = saved(db), record = record, expectA = expectA, expectB = expectB, key = key }
end

local function recoverBoth(a: Profile.Data, b: Profile.Data, rec: TradeLog.Record)
	Test.eq(Recovery.isCommitted(rec :: any), true)
	Recovery.recover(a :: any, rec :: any, A, 5000)
	Recovery.recover(b :: any, rec :: any, B, 5000)
end

Test.case("the trade itself ends with each player holding what the other offered", function()
	local sc = scenario()
	Test.eq(holdings(sc.a2), sc.expectA)
	Test.eq(holdings(sc.b2), sc.expectB)
end)

Test.case("crash before the log write: the pending note is dropped and nothing changed", function()
	local sc = scenario()
	-- No record exists, so the server discards the pending note on load.
	local a, b = saved(sc.a1), saved(sc.b1)
	Test.eq(#a.tradeJournal.pending, 1)
	Recovery.discard(a :: any, "trade-1")
	Recovery.discard(b :: any, "trade-1")
	Test.eq(#a.tradeJournal.pending, 0)
	Test.eq(holdings(a), holdings(sc.a0), "Ana's items are untouched")
	Test.eq(holdings(b), holdings(sc.b0), "Ben's items are untouched")
	Test.eq(a.tradeJournal.applied, {})
end)

Test.case("crash after the log write but before the swap: both players are rolled forward", function()
	local sc = scenario()
	local a, b = saved(sc.a1), saved(sc.b1) -- both profiles are still pre-swap on disk
	recoverBoth(a, b, sc.record)
	Test.eq(holdings(a), sc.expectA)
	Test.eq(holdings(b), sc.expectB)
	Test.eq(#a.tradeJournal.pending, 0)
	Test.truthy(Recovery.isApplied(a :: any, "trade-1") and Recovery.isApplied(b :: any, "trade-1"))
end)

Test.case("crash after the swap with only Ana saved: no duplicates, no losses", function()
	local sc = scenario()
	local a, b = saved(sc.a2), saved(sc.b1) -- Ana is post-swap on disk, Ben is still pre-swap
	local before = everything(a, b)
	Test.truthy(table.concat(before, "|") ~= table.concat(everything(sc.a0, sc.b0), "|"), "without recovery the items are duplicated or lost")
	recoverBoth(a, b, sc.record)
	Test.eq(holdings(a), sc.expectA)
	Test.eq(holdings(b), sc.expectB)
	Test.eq(everything(a, b), everything(sc.a0, sc.b0), "every item exists exactly once")
end)

Test.case("crash after the swap with only Ben saved", function()
	local sc = scenario()
	local a, b = saved(sc.a1), saved(sc.b2)
	recoverBoth(a, b, sc.record)
	Test.eq(holdings(a), sc.expectA)
	Test.eq(holdings(b), sc.expectB)
	Test.eq(everything(a, b), everything(sc.a0, sc.b0))
end)

Test.case("crash after the swap with neither saved is the same as before the swap", function()
	local sc = scenario()
	local a, b = saved(sc.a1), saved(sc.b1)
	recoverBoth(a, b, sc.record)
	Test.eq(holdings(a), sc.expectA)
	Test.eq(holdings(b), sc.expectB)
end)

Test.case("both saved after the swap: recovery finds nothing to do", function()
	local sc = scenario()
	local a, b = saved(sc.a2), saved(sc.b2)
	Test.eq(#a.tradeJournal.pending, 0)
	Test.eq(Recovery.recover(a :: any, sc.record :: any, A, 9), "already")
	Test.eq(Recovery.recover(b :: any, sc.record :: any, B, 9), "already")
	Test.eq(holdings(a), sc.expectA)
	Test.eq(holdings(b), sc.expectB)
end)

Test.case("recovery is idempotent: running it again changes nothing", function()
	local sc = scenario()
	local a, b = saved(sc.a1), saved(sc.b1)
	recoverBoth(a, b, sc.record)
	local afterA, afterB = holdings(a), holdings(b)
	Test.eq(Recovery.recover(a :: any, sc.record :: any, A, 9), "already")
	Test.eq(Recovery.recover(b :: any, sc.record :: any, B, 9), "already")
	Test.eq(holdings(a), afterA)
	Test.eq(holdings(b), afterB)
	-- It also survives being saved and loaded in between.
	local a3 = saved(a)
	Test.eq(Recovery.recover(a3 :: any, sc.record :: any, A, 9), "already")
	Test.eq(holdings(a3), afterA)
end)

Test.case("the two players can recover in either order, or hours apart", function()
	local sc = scenario()
	local a, b = saved(sc.a1), saved(sc.b1)
	Recovery.recover(b :: any, sc.record :: any, B, 1)
	Recovery.recover(a :: any, sc.record :: any, A, 99999)
	Test.eq(holdings(a), sc.expectA)
	Test.eq(holdings(b), sc.expectB)
end)

Test.case("recovered profiles are valid: unique ids, loadable, Part Index filled, no equipped traded pet", function()
	local sc = scenario()
	local a, b = saved(sc.a1), saved(sc.b1)
	-- Ana had equipped the pet she traded (as a stale profile might).
	Crafting.equip(a :: any, a.pets[1].uid)
	recoverBoth(a, b, sc.record)
	Test.eq(a.equippedPets, {}, "a traded pet cannot stay equipped")
	Test.eq(Profile.load(a, Config), a)
	Test.eq(Profile.load(b, Config), b)
	Test.truthy(b.index.Chicken_Head ~= nil and b.index.Kraken_Body ~= nil, "receiver's Part Index records the parts")
	Test.truthy(a.index.Fox_Tail ~= nil and a.index.Owl_Head ~= nil)
	local uids: { [number]: boolean } = {}
	for _, it in b.parts do
		Test.truthy(not uids[it.uid], "unique uid")
		uids[it.uid] = true
	end
end)

Test.case("only the two players in a record can recover it", function()
	local sc = scenario()
	local stranger = fresh()
	Test.eq(Recovery.recover(stranger :: any, sc.record :: any, 999, 1), "not_a_party")
	Test.eq(#stranger.parts, 0)
end)

Test.case("only completed records are committed; failed, cancelled or missing ones are not", function()
	local sc = scenario()
	Test.eq(Recovery.isCommitted(sc.record :: any), true)
	local failed = table.clone(sc.record)
	failed.status = "failed"
	Test.eq(Recovery.isCommitted(failed :: any), false)
	failed.status = "cancelled"
	Test.eq(Recovery.isCommitted(failed :: any), false)
	Test.eq(Recovery.isCommitted(nil), false)
end)

Test.case("the failed-after-commit record shares the trade's time so its key is predictable", function()
	local sc = scenario()
	local failed = table.clone(sc.record)
	failed.id = sc.record.id .. "_f"
	Test.eq(TradeLog.key(failed), TradeLog.supersededKey(sc.record), "the service writes it, recovery looks it up")
	Test.truthy(TradeLog.key(failed) ~= sc.key)
	Test.eq(TradeLog.supersededKey(sc.record), "T" .. string.sub(sc.key, 2, 12) .. "_trade-1_f")
end)

Test.case("the journal survives saving and loading, and hostile journals are repaired", function()
	local d = fresh()
	Recovery.begin(d :: any, "x1", "Tkey1")
	Recovery.settle(d :: any, "x0")
	local loaded = saved(d)
	Test.eq(loaded.tradeJournal, d.tradeJournal)
	local bad = Profile.load({ tradeJournal = { pending = { "junk", { id = 5 }, { id = "ok", key = "k" } }, applied = { 1, "fine", string.rep("x", 500) } } }, Config)
	Test.eq(bad.tradeJournal.pending, { { id = "ok", key = "k" } })
	Test.eq(bad.tradeJournal.applied, { "fine" })
	for i = 1, 100 do
		Recovery.settle(d :: any, "t" .. i)
	end
	Test.eq(#d.tradeJournal.applied, 50, "only recent ids are kept")
	Test.eq(d.tradeJournal.applied[50], "t100")
end)

Test.done()
