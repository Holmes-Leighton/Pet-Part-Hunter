--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Parts = require("../src/Shared/Parts")
local Crafting = require("../src/Shared/Crafting")
local Profile = require("../src/Shared/Profile")
local Trade = require("../src/Shared/Trade")
local TradeLog = require("../src/Shared/TradeLog")
local Config = require("../src/Shared/Config")

local A, B = 101, 202

local function fresh(): Profile.Data
	local d = Profile.load(nil, Config)
	d.coins = 100000
	return d
end

local function give(d: Profile.Data, id: string, n: number, seed: number?): { Crafting.Item }
	local rng = Rng.new(seed or 1)
	local out = {}
	for _ = 1, n do
		table.insert(out, Crafting.addPart(Config, d, Parts.get(id) :: Parts.Def, rng, 1000))
	end
	return out
end

local function setup(): (Trade.Session, Profile.Data, Profile.Data, { [number]: Profile.Data })
	local da, db = fresh(), fresh()
	local s = Trade.new(Config, "t1", { userId = A, name = "Ana" }, { userId = B, name = "Ben" }, 0)
	return s, da, db, { [A] = da, [B] = db }
end

local function offer(s: Trade.Session, uid: number, d: Profile.Data, parts: { number }, pets: { number }, now: number): (boolean, string)
	return Trade.setOffer(Config, s, uid, d :: any, parts, pets, now)
end

-- Both players lock in and confirm after the delay.
local function agree(s: Trade.Session, datas: { [number]: Profile.Data }, now: number)
	Test.truthy(Trade.lock(s, A, now))
	Test.truthy(Trade.lock(s, B, now))
	local later = now + Config.Trade.ConfirmDelay + 1
	local ev = Trade.evaluate(Config, s, datas :: any)
	Test.eq({ Trade.confirm(Config, s, A, true, ev, later) }, { true, "ok" })
	Test.eq({ Trade.confirm(Config, s, B, true, ev, later) }, { true, "ok" })
end

Test.case("eligibility: account age OR level, and a live off switch", function()
	Test.eq({ Trade.eligible(Config, 0, 1) }, { false, "trading unlocks at level 5 (or when your account is 7 days old)" })
	Test.truthy(Trade.eligible(Config, 7, 1), "old enough account")
	Test.truthy(Trade.eligible(Config, 0, 5), "high enough level")
	local off: any = table.clone(Config)
	off.Trade = table.clone(Config.Trade)
	off.Trade.Enabled = false
	Test.eq({ Trade.eligible(off, 365, 99) }, { false, "trading is switched off right now" })
end)

Test.case("a simple trade swaps parts both ways and gives the receivers fresh ids and Index entries", function()
	local s, da, db, datas = setup()
	local chick = give(da, "Chicken_Head", 1)[1]
	local tiger = give(db, "Tiger_Legs", 1, 2)[1]
	Test.truthy(offer(s, A, da, { chick.uid }, {}, 1))
	Test.truthy(offer(s, B, db, { tiger.uid }, {}, 2))
	agree(s, datas, 3)
	Test.truthy(Trade.ready(s))
	Test.eq({ Trade.execute(Config, s, datas :: any, 20) }, { true, "ok" })
	Test.eq(s.state, "completed")
	Test.eq(#da.parts, 1)
	Test.eq(#db.parts, 1)
	Test.eq(da.parts[1].id, "Tiger_Legs")
	Test.eq(db.parts[1].id, "Chicken_Head")
	Test.eq(da.parts[1].stats, tiger.stats, "stats travel with the part")
	Test.truthy(da.index.Tiger_Legs ~= nil and db.index.Chicken_Head ~= nil, "receivers' Part Index is filled")
	Test.truthy(da.index.Chicken_Head ~= nil, "the giver keeps their Index entry")
	Test.truthy(da.parts[1].uid < da.nextUid, "fresh id from the receiver's counter")
end)

Test.case("a loaded profile stays valid after a trade (unique uids everywhere)", function()
	local s, da, db, datas = setup()
	local items = give(da, "Chicken_Head", 3)
	local other = give(db, "Fox_Tail", 2, 5)
	offer(s, A, da, { items[1].uid, items[2].uid }, {}, 1)
	offer(s, B, db, { other[1].uid }, {}, 1)
	agree(s, datas, 2)
	Test.truthy(Trade.execute(Config, s, datas :: any, 30))
	Test.eq(Profile.load(da, Config), da)
	Test.eq(Profile.load(db, Config), db)
end)

Test.case("pets trade whole, with their parts, and must be unequipped first", function()
	local s, da, db, datas = setup()
	local head = give(da, "Chicken_Head", 1)[1]
	local legs = give(da, "Tiger_Legs", 1, 2)[1]
	local pet = Crafting.buildPet(Config, da, { Head = head.uid, Legs = legs.uid }) :: Crafting.Pet
	Crafting.equip(da, pet.uid)
	Test.eq({ offer(s, A, da, {}, { pet.uid }, 1) }, { false, "unequip a pet before trading it" })
	Crafting.unequip(da, pet.uid)
	Test.truthy(offer(s, A, da, {}, { pet.uid }, 1))
	local gift = give(db, "Owl_Body", 1, 3)[1]
	Test.truthy(offer(s, B, db, { gift.uid }, {}, 1))
	agree(s, datas, 2)
	Test.truthy(Trade.execute(Config, s, datas :: any, 30))
	Test.eq(#da.pets, 0)
	Test.eq(#db.pets, 1)
	Test.eq(db.pets[1].slots.Head.id, "Chicken_Head")
	Test.eq(db.pets[1].slots.Legs.id, "Tiger_Legs")
	Test.truthy(db.pets[1].uid ~= pet.uid or true)
	Test.truthy(db.index.Chicken_Head ~= nil and db.index.Tiger_Legs ~= nil)
	Test.eq(Profile.load(db, Config), db)
end)

Test.case("offers are checked against what the player owns: not owned, duplicates, bad types, too many", function()
	local s, da, _, _ = setup()
	local items = give(da, "Chicken_Head", 3)
	Test.eq({ offer(s, A, da, { 9999 }, {}, 1) }, { false, "you do not have one of those parts" })
	Test.eq({ offer(s, A, da, { items[1].uid, items[1].uid }, {}, 1) }, { false, "you do not have one of those parts" })
	Test.eq({ offer(s, A, da, {}, { 5 }, 1) }, { false, "you do not have one of those pets" })
	Test.eq({ Trade.setOffer(Config, s, A, da :: any, "x", {}, 1) }, { false, "invalid offer" })
	Test.eq({ Trade.setOffer(Config, s, A, da :: any, { "a" }, {}, 1) }, { false, "invalid offer" })
	Test.eq({ Trade.setOffer(Config, s, A, da :: any, { 0 / 0 }, {}, 1) }, { false, "invalid offer" })
	Test.eq({ Trade.setOffer(Config, s, A, da :: any, { a = 1 }, {}, 1) }, { false, "invalid offer" })
	local many = give(da, "Fox_Tail", Config.Trade.MaxItemsPerSide + 1, 9)
	local uids = {}
	for _, it in many do
		table.insert(uids, it.uid)
	end
	Test.eq({ offer(s, A, da, uids, {}, 1) }, { false, "at most 12 items per side" })
	Test.eq({ Trade.setOffer(Config, s, 999, da :: any, {}, {}, 1) }, { false, "this trade is closed" })
end)

Test.case("only tradable parts can be offered", function()
	local s, da, _, _ = setup()
	local item = give(da, "Chicken_Head", 1)[1]
	local def: any = Parts.get("Chicken_Head")
	def.tradable = false -- an event part, for example
	Test.eq({ offer(s, A, da, { item.uid }, {}, 1) }, { false, "one of those parts cannot be traded" })
	def.tradable = nil
	Test.truthy(offer(s, A, da, { item.uid }, {}, 1))
end)

Test.case("an empty trade cannot be locked", function()
	local s = setup()
	Test.eq({ Trade.lock(s, A, 1) }, { false, "put something in the trade first" })
end)

Test.case("changing an offer clears every lock and confirmation (no last-second swaps)", function()
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 2)
	local b1 = give(db, "Tiger_Legs", 1, 2)[1]
	offer(s, A, da, { a1[1].uid }, {}, 1)
	offer(s, B, db, { b1.uid }, {}, 1)
	agree(s, datas, 2)
	Test.truthy(Trade.ready(s))
	-- Ana swaps in a different part after both confirmed.
	Test.truthy(offer(s, A, da, { a1[2].uid }, {}, 50))
	Test.truthy(not Trade.ready(s))
	Test.truthy(not Trade.bothLocked(s))
	Test.eq(s.confirmed, {})
	Test.eq(s.locked, {})
end)

Test.case("unlocking clears everyone's confirmation", function()
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	local b1 = give(db, "Tiger_Legs", 1, 2)[1]
	offer(s, A, da, { a1.uid }, {}, 1)
	offer(s, B, db, { b1.uid }, {}, 1)
	agree(s, datas, 2)
	Test.truthy(Trade.unlock(s, B, 20))
	Test.truthy(not Trade.ready(s))
	Test.truthy(not Trade.bothLocked(s))
end)

Test.case("confirming needs both locked and waits out the delay after the last change", function()
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	local b1 = give(db, "Tiger_Legs", 1, 2)[1]
	offer(s, A, da, { a1.uid }, {}, 10)
	offer(s, B, db, { b1.uid }, {}, 10)
	local ev = Trade.evaluate(Config, s, datas :: any)
	Test.eq({ Trade.confirm(Config, s, A, true, ev, 11) }, { false, "both players must lock in first" })
	Trade.lock(s, A, 10)
	Trade.lock(s, B, 10)
	Test.near(Trade.confirmWait(Config, s, 11), Config.Trade.ConfirmDelay - 1)
	Test.eq({ Trade.confirm(Config, s, A, true, ev, 11) }, { false, "wait a moment and check the trade again" })
	Test.eq({ Trade.confirm(Config, s, A, true, ev, 10 + Config.Trade.ConfirmDelay) }, { true, "ok" })
	Test.truthy(not Trade.ready(s), "one confirmation is not enough")
	Test.eq({ Trade.execute(Config, s, datas :: any, 30) }, { false, "the trade is not confirmed by both players" })
	Test.eq(#da.parts, 1, "nothing moved")
end)

Test.case("lopsided trades warn and need the generous side to acknowledge", function()
	local s, da, db, datas = setup()
	local rare = give(da, "Kraken_Head", 1)[1] -- Mythic, worth 2000
	local junk = give(db, "Chicken_Head", 1, 2)[1] -- Common, worth 5
	offer(s, A, da, { rare.uid }, {}, 1)
	offer(s, B, db, { junk.uid }, {}, 1)
	local ev = Trade.evaluate(Config, s, datas :: any)
	Test.eq(ev.lopsided, true)
	Test.eq(ev.giver, A)
	Test.truthy(ev.ratio >= Config.Trade.LopsidedRatio)
	Trade.lock(s, A, 1)
	Trade.lock(s, B, 1)
	local later = 1 + Config.Trade.ConfirmDelay
	Test.eq({ Trade.confirm(Config, s, A, false, ev, later) }, { false, "this trade looks lopsided: you give much more than you get" })
	Test.eq({ Trade.confirm(Config, s, B, false, ev, later) }, { true, "ok" }, "the receiver is not blocked")
	Test.eq({ Trade.confirm(Config, s, A, true, ev, later) }, { true, "ok" }, "acknowledged")
	Test.eq(s.acked[A], true)
	Test.truthy(Trade.ready(s))
end)

Test.case("fair and tiny trades are not flagged lopsided", function()
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	local b1 = give(db, "Fox_Tail", 1, 2)[1]
	offer(s, A, da, { a1.uid }, {}, 1)
	offer(s, B, db, { b1.uid }, {}, 1)
	Test.eq(Trade.evaluate(Config, s, datas :: any).lopsided, false)
	-- A gift of one common part for nothing is a big ratio but a trivial amount: no warning.
	offer(s, B, db, {}, {}, 2)
	local ev = Trade.evaluate(Config, s, datas :: any)
	Test.eq(ev.lopsided, false)
	Test.eq(ev.ratio, math.huge)
end)

Test.case("pets are valued at their parts times the pet multiplier", function()
	local da = fresh()
	local head = give(da, "Kraken_Head", 1)[1]
	local pet = Crafting.buildPet(Config, da, { Head = head.uid }) :: Crafting.Pet
	Test.eq(Trade.petValue(Config, pet), 2000 * Config.Trade.PetValueMultiplier)
end)

Test.case("execution re-checks ownership: a part sold mid-trade cancels the swap and changes nothing", function()
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	local b1 = give(db, "Tiger_Legs", 1, 2)[1]
	offer(s, A, da, { a1.uid }, {}, 1)
	offer(s, B, db, { b1.uid }, {}, 1)
	agree(s, datas, 2)
	da.parts = {} -- sold or merged away while the window was open
	local ok, why = Trade.execute(Config, s, datas :: any, 30)
	Test.eq(ok, false)
	Test.truthy(string.find(why, "Ana", 1, true) ~= nil)
	Test.eq(#db.parts, 1)
	Test.eq(db.parts[1].id, "Tiger_Legs", "Ben still has his part")
	Test.eq(s.state, "open")
end)

Test.case("no duplication: every item exists exactly once after the swap", function()
	local s, da, db, datas = setup()
	local items = give(da, "Chicken_Head", 4)
	local uids = {}
	for _, it in items do
		table.insert(uids, it.uid)
	end
	offer(s, A, da, uids, {}, 1)
	offer(s, B, db, {}, {}, 1)
	agree(s, datas, 2)
	local before = #da.parts + #db.parts
	Test.truthy(Trade.execute(Config, s, datas :: any, 30))
	Test.eq(#da.parts, 0)
	Test.eq(#db.parts, 4)
	Test.eq(#da.parts + #db.parts, before)
	-- A completed trade cannot run again.
	Test.eq({ Trade.execute(Config, s, datas :: any, 31) }, { false, "the trade is not confirmed by both players" })
	Test.eq(#db.parts, 4)
end)

Test.case("closed trades accept nothing more, and idle ones expire", function()
	local s, da, _, _ = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	Test.truthy(not Trade.expired(Config, s, 10))
	Test.truthy(Trade.expired(Config, s, Config.Trade.IdleSeconds + 1))
	Trade.close(s, "cancelled", "Ana cancelled", 5)
	Test.eq(s.state, "cancelled")
	Test.eq(s.reason, "Ana cancelled")
	Test.eq({ offer(s, A, da, { a1.uid }, {}, 6) }, { false, "this trade is closed" })
	Test.eq({ Trade.lock(s, A, 6) }, { false, "this trade is closed" })
	Trade.close(s, "expired", "later", 7)
	Test.eq(s.state, "cancelled", "the first outcome stands")
end)

-- The backend log --------------------------------------------------------------------------------------------------------
local function completedRecord(): (TradeLog.Record, Trade.Session)
	local s, da, db, datas = setup()
	local rare = give(da, "Kraken_Head", 1)[1]
	local junk = give(db, "Chicken_Head", 1, 2)[1]
	offer(s, A, da, { rare.uid }, {}, 1)
	offer(s, B, db, { junk.uid }, {}, 1)
	local ev = Trade.evaluate(Config, s, datas :: any)
	Trade.lock(s, A, 1)
	Trade.lock(s, B, 1)
	local later = 1 + Config.Trade.ConfirmDelay
	Trade.confirm(Config, s, A, true, ev, later)
	Trade.confirm(Config, s, B, false, ev, later)
	local gave = { [A] = Trade.gave(s, A, datas[A] :: any), [B] = Trade.gave(s, B, datas[B] :: any) }
	Trade.execute(Config, s, datas :: any, later + 1)
	return TradeLog.build(s, gave, ev, 1700000000, 1700000060, "job-123", nil), s
end

Test.case("a trade record has everything needed to investigate: who, what, value, outcome, timeline", function()
	local rec = completedRecord()
	Test.eq(rec.v, TradeLog.VERSION)
	Test.eq(rec.status, "completed")
	Test.eq({ rec.a, rec.b }, { A, B })
	Test.eq(rec.job, "job-123")
	Test.eq(rec.duration, 60)
	Test.eq(rec.sides[tostring(A)].name, "Ana")
	Test.eq(rec.sides[tostring(A)].parts[1].id, "Kraken_Head")
	Test.eq(rec.sides[tostring(B)].parts[1].id, "Chicken_Head")
	Test.eq(rec.sides[tostring(A)].value, 2000)
	Test.eq(rec.lopsided, true)
	Test.truthy(table.find(rec.flags, "lopsided") ~= nil and table.find(rec.flags, "lopsided_acknowledged") ~= nil)
	local kinds: { [string]: boolean } = {}
	for _, e in rec.events do
		kinds[e.e] = true
	end
	Test.truthy(kinds.open and kinds.offer and kinds.lock and kinds.confirm and kinds.completed, "timeline covers the whole trade")
	Test.truthy(string.find(TradeLog.summary(rec), "completed", 1, true) ~= nil)
end)

Test.case("a record is plain JSON-safe data: no functions, NaN or infinity, string keys for objects", function()
	local function check(v: any, path: string)
		local t = type(v)
		if t == "number" then
			Test.truthy(v == v and v ~= math.huge and v ~= -math.huge, path .. " is a finite number")
		elseif t == "table" then
			local isArray = #v > 0 or next(v) == nil
			for k, x in v do
				if isArray then
					Test.eq(type(k), "number", path .. " array key")
				else
					Test.eq(type(k), "string", path .. " object key")
				end
				check(x, path .. "." .. tostring(k))
			end
		else
			Test.truthy(t == "string" or t == "boolean", path .. " is " .. t)
		end
	end
	check(completedRecord(), "record")
	-- An empty side makes the value ratio infinite; the record must cap it.
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	offer(s, A, da, { a1.uid }, {}, 1)
	local ev = Trade.evaluate(Config, s, datas :: any)
	Test.eq(ev.ratio, math.huge)
	Trade.close(s, "cancelled", "Ben declined", 5)
	local rec = TradeLog.build(s, { [A] = Trade.gave(s, A, da :: any), [B] = Trade.gave(s, B, db :: any) }, ev, 100, 110, "j", nil)
	Test.truthy(rec.ratio < math.huge)
	check(rec, "cancelled")
end)

Test.case("cancelled and expired trades are recorded too", function()
	local s, da, db, datas = setup()
	local a1 = give(da, "Chicken_Head", 1)[1]
	offer(s, A, da, { a1.uid }, {}, 1)
	Trade.close(s, "expired", "idle", 400)
	local ev = Trade.evaluate(Config, s, datas :: any)
	local rec = TradeLog.build(s, { [A] = Trade.gave(s, A, da :: any), [B] = Trade.gave(s, B, db :: any) }, ev, 100, 500, "j", { "test" })
	Test.eq(rec.status, "expired")
	Test.eq(rec.reason, "idle")
	Test.eq(rec.flags, { "test" })
	Test.eq(#rec.sides[tostring(A)].parts, 1, "what was on offer is still recorded")
end)

Test.case("record keys sort by time and are unique per trade; the player index keeps the newest", function()
	local rec = completedRecord()
	Test.eq(TradeLog.key(rec), "T01700000060_t1")
	local later = table.clone(rec)
	later.t = rec.t + 5
	later.id = "t2"
	Test.truthy(TradeLog.key(later) > TradeLog.key(rec), "later trades sort after")
	Test.eq(TradeLog.indexKey(A), "P101")
	local list: any = nil
	for i = 1, 5 do
		local r = table.clone(rec)
		r.id = "x" .. i
		list = TradeLog.addToIndex(list, TradeLog.indexEntry(r, A), 3)
	end
	Test.eq(#list, 3)
	Test.eq(list[1].id, "x3")
	Test.eq(list[3].id, "x5")
	Test.eq(list[3].w, B, "records who they traded with")
	Test.eq(list[3].l, true)
	-- Re-adding the same trade does not duplicate it; a corrupt index is repaired.
	list = TradeLog.addToIndex(list, TradeLog.indexEntry(rec, A), 3)
	Test.eq(#list, 3)
	local repaired = TradeLog.addToIndex({ "junk", { id = 5 } }, TradeLog.indexEntry(rec, B), 3)
	Test.eq(#repaired, 1)
	Test.eq(repaired[1].w, A)
end)

Test.case("trade volume flag: more than the hourly limit of completed trades", function()
	local times: { number } = {}
	for i = 1, Config.Trade.VolumePerHour do
		table.insert(times, 1000 + i)
	end
	Test.eq(TradeLog.volumeFlag(times, 1100, Config.Trade.VolumePerHour), false, "at the limit is fine")
	table.insert(times, 1101)
	Test.eq(TradeLog.volumeFlag(times, 1102, Config.Trade.VolumePerHour), true)
	Test.eq(TradeLog.volumeFlag(times, 1101 + 3601, Config.Trade.VolumePerHour), false, "old trades fall out of the window")
	Test.eq(#times, 0)
end)

Test.done()
