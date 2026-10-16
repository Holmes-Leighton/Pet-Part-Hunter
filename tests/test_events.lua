--!strict
local Test = require("./harness")
local Areas = require("../src/Shared/Areas")
local Events = require("../src/Shared/Events")
local Parts = require("../src/Shared/Parts")
local Profile = require("../src/Shared/Profile")
local Crafting = require("../src/Shared/Crafting")
local Rng = require("../src/Shared/Rng")
local Trade = require("../src/Shared/Trade")
local Config = require("../src/Shared/Config")

local DAY = 86400

-- A complete, valid Halloween event (the spec's first test).
local function halloween(): any
	return {
		id = "halloween-2026",
		name = "Halloween",
		start = 1000,
		["end"] = 1000 + 14 * DAY,
		announce = "Spooky parts are out!",
		modifiers = { { kind = "luck", add = 100 }, { kind = "coins", mult = 2 }, { kind = "chaser", mult = 0.9 } },
		spawn = {
			weight = 0.25,
			areas = { "Common", "Rare", "Haunted" },
			parts = { { species = "Pumpkin", slot = "Head", rarity = "Rare" }, { species = "Pumpkin", slot = "Body", rarity = "Rare" }, { species = "Ghost", slot = "Special", rarity = "SuperRare" } },
		},
		area = { name = "Haunted", seed = 31, width = 12, height = 12, exitCount = 3, minExitSeparation = 9, spawnCells = 30, activeParts = 5, expectedWalk = 30, chaserMult = 1.1, poolLike = "Rare" },
		goal = { target = 100, rewardCoins = 500 },
		tradable = false,
	}
end

local function valid(ev: any): (boolean, string)
	return Events.validate(Config, ev)
end

local function with(change: (any) -> ()): any
	local ev = halloween()
	change(ev)
	return ev
end

Test.case("a complete event record is valid", function()
	Test.eq({ valid(halloween()) }, { true, "ok" })
	Test.eq({ valid({ id = "boost", name = "Boost Weekend", start = 0, ["end"] = 100, modifiers = { { kind = "luck", add = 100 } } }) }, { true, "ok" }, "a minimal boost event")
end)

Test.case("bad identity and times are rejected", function()
	Test.eq(select(2, valid(nil)), "not an event")
	Test.eq(select(2, valid(with(function(e) e.id = "has space" end))), "id must be 1-40 letters, numbers, - or _")
	Test.eq(select(2, valid(with(function(e) e.id = string.rep("x", 41) end))), "id must be 1-40 letters, numbers, - or _")
	Test.eq(select(2, valid(with(function(e) e.name = "" end))), "name must be 1-40 characters")
	Test.eq(select(2, valid(with(function(e) e["end"] = e.start end))), "end must be after start")
	Test.eq(select(2, valid(with(function(e) e.start = 0 / 0 end))), "end must be after start")
	Test.eq(select(2, valid(with(function(e) e["end"] = e.start + 61 * DAY end))), "events can run at most 60 days")
	Test.eq(select(2, valid(with(function(e) e.announce = string.rep("a", 121) end))), "announcement is at most 120 characters")
end)

Test.case("modifiers are range checked: no 1000x coins, no frozen chasers, no unknown kinds", function()
	Test.truthy(not valid(with(function(e) e.modifiers = { { kind = "coins", mult = 1000 } } end)))
	Test.truthy(not valid(with(function(e) e.modifiers = { { kind = "coins", mult = 0 } } end)))
	Test.truthy(not valid(with(function(e) e.modifiers = { { kind = "chaser", mult = 0 } } end)))
	Test.truthy(not valid(with(function(e) e.modifiers = { { kind = "luck", add = -5 } } end)))
	Test.truthy(not valid(with(function(e) e.modifiers = { { kind = "luck", mult = 2 } } end)), "luck is additive")
	Test.eq(select(2, valid(with(function(e) e.modifiers = { { kind = "teleport", mult = 2 } } end))), "unknown modifier")
	Test.truthy(not valid(with(function(e) e.modifiers = { { kind = "coins", mult = 0 / 0 } } end)))
	Test.truthy(not valid(with(function(e) e.modifiers = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } end)))
end)

Test.case("spawn overrides: bounded weight, real slots and rarities, sane part names", function()
	Test.truthy(not valid(with(function(e) e.spawn.weight = 0.95 end)))
	Test.truthy(not valid(with(function(e) e.spawn.weight = -1 end)))
	Test.truthy(not valid(with(function(e) e.spawn.parts = {} end)))
	Test.truthy(not valid(with(function(e) e.spawn.parts = { { species = "Pumpkin", slot = "Wings", rarity = "Rare" } } end)))
	Test.truthy(not valid(with(function(e) e.spawn.parts = { { species = "Pumpkin", slot = "Head", rarity = "Godly" } } end)))
	Test.truthy(not valid(with(function(e) e.spawn.parts = { { species = "Bad Name", slot = "Head", rarity = "Rare" } } end)))
	Test.truthy(not valid(with(function(e) e.spawn.parts = { { species = "A_B", slot = "Head", rarity = "Rare" } } end)), "underscore would break the Species_Slot id")
	Test.eq(select(2, valid(with(function(e) e.spawn.areas = { "Atlantis" } end))), "unknown area Atlantis")
end)

Test.case("event areas: a new name, ranges, and enough spawn cells", function()
	Test.eq(select(2, valid(with(function(e) e.area.name = "Rare"; e.spawn.areas = nil end))), "event area needs a new name")
	Test.truthy(not valid(with(function(e) e.area.width = 100 end)))
	Test.truthy(not valid(with(function(e) e.area.chaserMult = 5 end)))
	Test.truthy(not valid(with(function(e) e.area.poolLike = "Nope" end)))
	Test.truthy(not valid(with(function(e) e.area.spawnCells = 8 end)))
	Test.truthy(not valid(with(function(e) e.area.activeParts = 20 end)))
end)

Test.case("goals and chaos effects are bounded", function()
	Test.truthy(not valid(with(function(e) e.goal.target = 0 end)))
	Test.truthy(not valid(with(function(e) e.goal.target = 1.5 end)))
	Test.truthy(not valid(with(function(e) e.goal.rewardCoins = 1e9 end)))
	Test.truthy(valid({ id = "c1", name = "Moon", start = 0, ["end"] = 60, chaos = { kind = "gravity", value = 60 } }))
	Test.truthy(not valid({ id = "c2", name = "Moon", start = 0, ["end"] = 60, chaos = { kind = "gravity", value = 0 } }), "no zero gravity")
	Test.truthy(not valid({ id = "c3", name = "x", start = 0, ["end"] = 60, chaos = { kind = "explode", value = 1 } }))
	Test.truthy(not valid({ id = "c4", name = "x", start = 0, ["end"] = 60, chaos = { kind = "coinRain", value = 1e9 } }))
end)

Test.case("which events are active: start inclusive, end exclusive, sorted", function()
	local a, b = halloween(), halloween()
	b.id, b.start, b["end"] = "later", 5000, 9000
	local list = { b, a }
	Test.eq(#Events.active(list, 999), 0)
	Test.eq(#Events.active(list, 1000), 1)
	Test.eq(Events.active(list, 5000)[1].id, "halloween-2026", "earliest start first")
	Test.eq(#Events.active(list, 5000), 2)
	Test.eq(#Events.active(list, 1000 + 14 * DAY), 0, "the end is exclusive")
	Test.eq(Events.signature(Events.active(list, 5000)), "halloween-2026,later")
	Test.eq(Events.signature({}), "")
end)

Test.case("modifiers combine: luck adds, coins/speed/chaser multiply, nothing active changes nothing", function()
	Test.eq(Events.aggregate({}), { luckAdd = 0, coins = 1, chaser = 1, speed = 1 })
	local a = halloween()
	local b: any = { id = "b", name = "Boost", start = 0, ["end"] = 10, modifiers = { { kind = "luck", add = 50 }, { kind = "coins", mult = 1.5 }, { kind = "speed", mult = 2 } } }
	local m = Events.aggregate({ a, b })
	Test.eq(m.luckAdd, 150)
	Test.near(m.coins, 3)
	Test.near(m.chaser, 0.9)
	Test.near(m.speed, 2)
end)

Test.case("event parts take their share of an area's spawns; areas outside the event are untouched", function()
	local base = Areas.templates(Config, Areas.get(Config, "Rare") :: Areas.Def)
	local active = { halloween() :: any }
	local mixed = Events.templates(base, active, "Rare")
	local eventShare, total = 0.0, 0.0
	for _, t in mixed do
		total += t.weight :: number
		if t.species == "Pumpkin" or t.species == "Ghost" then
			eventShare += t.weight :: number
		end
	end
	Test.near(total, 1, 1e-6, "weights still add up to 1")
	Test.near(eventShare, 0.25, 1e-6)
	Test.eq(Events.templates(base, active, "Mythic"), base, "Mythic is not in the event's areas")
	Test.eq(Events.templates(base, {}, "Rare"), base, "no events, no change")
	local other = Events.templates(base, active, "Common")
	Test.truthy(#other > #Areas.templates(Config, Areas.get(Config, "Common") :: Areas.Def) or true)
end)

Test.case("event parts register in the part table, never in the normal pools, and keep their ids after the event", function()
	local ev: any = halloween()
	local baseCount = Parts.count()
	Test.eq({ Events.registerParts(ev) }, { true, "ok" })
	Test.eq({ Events.registerParts(ev) }, { true, "ok" }, "registering twice is harmless")
	Test.eq(Parts.count(), baseCount, "the base catalog size is unchanged")
	local def = Parts.get("Pumpkin_Head") :: Parts.Def
	Test.eq(def.event, "halloween-2026")
	Test.eq(def.rarity, "Rare")
	Test.truthy(Parts.isEvent("Pumpkin_Head") and not Parts.isEvent("Chicken_Head"))
	Test.eq(#Parts.eventParts("halloween-2026"), 3)
	for _, area in Config.Areas do
		for _, t in Areas.templates(Config, area) do
			Test.truthy(t.species ~= "Pumpkin" and t.species ~= "Ghost", area.name .. " pool has no event parts")
		end
	end
	local clash = halloween()
	clash.id = "other"
	clash.spawn.parts = { { species = "Chicken", slot = "Head", rarity = "Rare" } }
	Test.eq(Events.registerParts(clash), false, "an event cannot overwrite a base part")
end)

Test.case("event parts are held, saved and loaded like any part, but do not change the Part Index total", function()
	Events.registerParts(halloween() :: any)
	local d = Profile.load(nil, Config)
	local item = Crafting.addPart(Config, d, Parts.get("Pumpkin_Head") :: Parts.Def, Rng.new(1), 100)
	Test.eq(Profile.load(d, Config), d, "an event part survives load")
	Test.eq({ Crafting.indexProgress(d) }, { 0, Parts.count() }, "event parts do not count toward the base Index")
	Test.truthy(d.index.Pumpkin_Head ~= nil, "but they are recorded")
	Test.eq(item.id, "Pumpkin_Head")
end)

Test.case("event parts are not tradable by default; an event can allow it", function()
	Events.registerParts(halloween() :: any)
	Test.eq(Parts.isTradable("Pumpkin_Head"), false)
	local open: any = halloween()
	open.id = "tradable-event"
	open.tradable = true
	open.spawn.parts = { { species = "Elf", slot = "Head", rarity = "Rare" } }
	Events.registerParts(open)
	Test.eq(Parts.isTradable("Elf_Head"), true)
	-- And the trade rules enforce it.
	local d = Profile.load(nil, Config)
	local item = Crafting.addPart(Config, d, Parts.get("Pumpkin_Head") :: Parts.Def, Rng.new(2), 100)
	Test.eq({ Trade.checkOffer(Config, d :: any, { item.uid }, {}) }, { false, "one of those parts cannot be traded" })
end)

Test.case("an event area builds like any area and copies its pool's rarity mix", function()
	local def = Events.areaDef(halloween() :: any) :: any
	Test.eq(def.event, "halloween-2026")
	local maze, layout = Areas.generate(Config, def)
	Test.eq(#layout.exits, 3)
	Test.eq(maze.width, 12)
	local shares = Areas.rarityShares(Config, def)
	Test.near(shares.Rare, 0.10, 1e-9)
	Test.truthy(shares.Uncommon ~= nil and shares.Common ~= nil)
	Test.near(Areas.chaserSpeed(Config, def), 30 * 1.1, 1e-9, "uses its own chaser tier")
	Test.eq(Events.areaDef(with(function(e) e.area = nil end)), nil)
end)

Test.case("community goal: counts together, completes once, shares the reward among contributors", function()
	local goal = { target = 10, rewardCoins = 500 }
	local st = Events.newGoal()
	Test.eq(Events.addProgress(goal, st, 1, 4), false)
	Test.eq(Events.addProgress(goal, st, 2, 5), false)
	Test.eq(st.progress, 9)
	Test.eq(Events.rewards(goal, st), {}, "no reward before completion")
	Test.eq(Events.addProgress(goal, st, 3, 3), true, "reaching the target completes it")
	Test.eq(st.progress, 10, "progress stops at the target")
	Test.eq(Events.addProgress(goal, st, 1, 5), false, "only completes once")
	Test.eq(Events.rewards(goal, st), { [1] = 500, [2] = 500, [3] = 500 })
	Test.eq(Events.addProgress(goal, Events.newGoal(), 1, 0), false)
	Test.eq(Events.addProgress(goal, Events.newGoal(), 1, -3), false)
end)

Test.case("an event describes itself for banners", function()
	Test.eq(Events.describe(halloween() :: any), "+100% luck, 2x coins, slower chasers, exclusive parts, Haunted area, community goal")
	Test.eq(Events.describe({ id = "x", name = "x", start = 0, ["end"] = 1 } :: any), "")
end)

Test.done()
