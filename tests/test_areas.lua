--!strict
local Test = require("./harness")
local Areas = require("../src/Shared/Areas")
local Maze = require("../src/Shared/Maze")
local Parts = require("../src/Shared/Parts")
local Profile = require("../src/Shared/Profile")
local Config = require("../src/Shared/Config")

local function fresh(): Profile.Data
	return Profile.load(nil, Config)
end

local function def(name: string): Areas.Def
	return Areas.get(Config, name) :: Areas.Def
end

Test.case("six areas in rarity order, each with a chaser tier and a rarity of parts to hunt", function()
	Test.eq(Areas.names(Config), { "Common", "Uncommon", "Rare", "SuperRare", "Legendary", "Mythic" })
	Test.eq(Areas.get(Config, "Nowhere"), nil)
	Test.eq(Areas.index(Config, "Rare"), 3)
	local prev = 0.0
	for _, d in Config.Areas do
		Test.truthy(Config.Chase.SpeedMultiplier[d.name] ~= nil, d.name .. " has a chaser multiplier")
		Test.truthy((Config.Rarity :: any)[d.name] ~= nil, d.name .. " rarity has a stat range")
		Test.truthy(d.expectedWalk > prev, d.name .. " expects a faster player than the tier below")
		prev = d.expectedWalk
	end
end)

Test.case("spec chaser multipliers: 0.85, 0.95, 1.05, 1.15, 1.25, 1.35", function()
	local want: { [string]: number } = { Common = 0.85, Uncommon = 0.95, Rare = 1.05, SuperRare = 1.15, Legendary = 1.25, Mythic = 1.35 }
	for name, m in want do
		Test.near(Config.Chase.SpeedMultiplier[name], m)
	end
end)

Test.case("chaser speed rises with the tier and is set against the area's expected player speed", function()
	local prev = 0.0
	for _, d in Config.Areas do
		local s = Areas.chaserSpeed(Config, d)
		Test.near(s, d.expectedWalk * Config.Chase.SpeedMultiplier[d.name], 1e-9)
		Test.truthy(s > prev, d.name)
		prev = s
	end
	Test.truthy(Areas.chaserSpeed(Config, def("Common")) < Config.Player.WalkSpeed, "Common is slower than a new player")
	Test.truthy(Areas.chaserSpeed(Config, def("Rare")) > def("Rare").expectedWalk, "Rare outruns the expected player (spec 1.05x)")
end)

Test.case("expected speeds are reachable: under the WalkCap, and Common matches a brand-new player", function()
	for _, d in Config.Areas do
		Test.truthy(d.expectedWalk <= Config.Speed.WalkCap, d.name)
	end
	Test.eq(def("Common").expectedWalk, Config.Player.WalkSpeed)
end)

Test.case("teleport-out points get fewer and further apart in higher areas", function()
	local prevSep, prevCount = 0, 99
	for _, d in Config.Areas do
		Test.truthy(d.minExitSeparation >= prevSep, d.name .. " exits not closer than the tier below")
		Test.truthy(d.exitCount <= prevCount, d.name .. " exits not more numerous")
		prevSep, prevCount = d.minExitSeparation, d.exitCount
	end
end)

Test.case("every area generates a maze with its exits at junctions, far from the entrance", function()
	for _, d in Config.Areas do
		local maze, layout = Areas.generate(Config, d)
		Test.eq(#layout.exits, d.exitCount, d.name .. " exit count")
		Test.truthy(#layout.spawnCells >= d.activeParts * 2, d.name .. " spawn cells")
		local dist = Maze.distances(maze, 1, 1)
		for _, e in layout.exits do
			Test.truthy(dist[(e.y - 1) * maze.width + e.x] >= d.minExitSeparation, d.name .. " exit far from the entrance")
			Test.truthy(#Maze.neighbors(maze, e.x, e.y) >= 3, d.name .. " exit at a junction")
		end
	end
end)

Test.case("generation is deterministic: same area, same maze on every server", function()
	local _, l1 = Areas.generate(Config, def("Rare"))
	local _, l2 = Areas.generate(Config, def("Rare"))
	Test.eq(l1.exits, l2.exits)
	Test.eq(l1.spawnCells, l2.spawnCells)
end)

local function share(templates: { Parts.Template }, rarity: string): number
	local total, mine = 0.0, 0.0
	for _, t in templates do
		total += t.weight or 1
		if t.rarity == rarity then
			mine += t.weight or 1
		end
	end
	return mine / total
end

Test.case("an area's name is its highest rarity: lower rarities spawn too, higher ones never (except drifting Specials)", function()
	for i, d in Config.Areas do
		local templates = Areas.templates(Config, d)
		for _, t in templates do
			local rarityIndex = Areas.index(Config, t.rarity) :: number
			if rarityIndex > i then
				Test.eq(t.slot, "Special", d.name .. ": only Special parts come from above")
			end
		end
		-- Every lower rarity is present.
		for lower = 1, i do
			Test.truthy(share(templates, Config.Areas[lower].name) > 0, d.name .. " spawns " .. Config.Areas[lower].name)
		end
	end
end)

Test.case("the area's own rarity is about 10% of finds in every area above Common; Common is all Common", function()
	local common = Areas.templates(Config, def("Common"))
	Test.truthy(share(common, "Common") > 0.95, "Common area is Common parts (plus a few drifting Specials)")
	for i = 2, #Config.Areas do
		local d = Config.Areas[i]
		local s = share(Areas.templates(Config, d), d.name)
		Test.truthy(s > 0.085 and s < 0.105, string.format("%s: own rarity share %.3f", d.name, s))
	end
end)

Test.case("a mid rarity is rarer in its own area than in a higher area (Rare is a bigger share of Mythic than of Rare)", function()
	local inRare = share(Areas.templates(Config, def("Rare")), "Rare")
	local inMythic = share(Areas.templates(Config, def("Mythic")), "Rare")
	Test.truthy(inMythic > inRare, string.format("Rare: %.3f in Rare vs %.3f in Mythic", inRare, inMythic))
	local inLegendary = share(Areas.templates(Config, def("Legendary")), "Rare")
	Test.truthy(inLegendary > inRare)
end)

Test.case("the top rarity is the rarest thing in its own area, and rarity gets scarcer the nearer the top", function()
	for i = 2, #Config.Areas do
		local shares = Areas.rarityShares(Config, Config.Areas[i])
		local top = shares[Config.Areas[i].name]
		local prev = top
		for lower = i - 1, 1, -1 do
			local s = shares[Config.Areas[lower].name]
			Test.truthy(s >= top - 1e-9, Config.Areas[i].name .. ": " .. Config.Areas[lower].name .. " is at least as common as the top rarity")
			Test.truthy(s <= (if lower == i - 1 then 1 else prev) + 1e-9, "tiers further below the top are not commoner than the one above them")
			prev = s
		end
	end
	local m = Areas.rarityShares(Config, def("Mythic"))
	Test.near(m.Mythic, 0.10, 1e-9)
	Test.truthy(m.Legendary > m.SuperRare and m.SuperRare > m.Rare and m.Rare > m.Uncommon and m.Uncommon > m.Common)
end)

Test.case("every area's weights add up to 1, and every template maps to a catalog part", function()
	for _, d in Config.Areas do
		local total = 0.0
		for _, t in Areas.templates(Config, d) do
			total += t.weight :: number
			Test.truthy(Parts.get(t.species .. "_" .. t.slot) ~= nil, "template maps to a catalog part")
		end
		Test.near(total, 1, 1e-9, d.name)
	end
end)

Test.case("Special parts of higher rarities drift into lower areas at a low rate", function()
	local drift = 0.0
	for _, t in Areas.templates(Config, def("Common")) do
		if t.rarity ~= "Common" then
			drift += t.weight :: number
		end
	end
	Test.near(drift, Config.Parts.SpecialDrift, 1e-9)
	local mythicAbove = 0
	for _, t in Areas.templates(Config, def("Mythic")) do
		if Areas.index(Config, t.rarity) :: number > 6 then
			mythicAbove += 1
		end
	end
	Test.eq(mythicAbove, 0, "nothing is above Mythic")
end)

Test.case("free areas are open from the start; paid areas are locked", function()
	local d = fresh()
	for _, n in { "Common", "Uncommon", "Rare" } do
		Test.truthy(Areas.canEnter(d, n), n)
	end
	for _, n in { "SuperRare", "Legendary", "Mythic" } do
		Test.truthy(not Areas.canEnter(d, n), n)
	end
	Test.truthy(not Areas.canEnter(d, "Nowhere"))
end)

Test.case("the free route: Rebirth 2, 4 and 6 unlock Super Rare, Legendary and Mythic", function()
	local d = fresh()
	d.rebirths = 1
	Test.eq(Areas.refreshUnlocks(Config, d), {})
	d.rebirths = 2
	Test.eq(Areas.refreshUnlocks(Config, d), { "SuperRare" })
	Test.truthy(Areas.canEnter(d, "SuperRare") and not Areas.canEnter(d, "Legendary"))
	d.rebirths = 4
	Test.eq(Areas.refreshUnlocks(Config, d), { "Legendary" })
	d.rebirths = 6
	Test.eq(Areas.refreshUnlocks(Config, d), { "Mythic" })
	Test.eq(Areas.refreshUnlocks(Config, d), {}, "nothing new the second time")
end)

Test.case("the pass is early access: one pass opens one area, the bundle opens all three", function()
	local d = fresh()
	d.passes.Area_Mythic = true
	Test.eq(Areas.refreshUnlocks(Config, d), { "Mythic" })
	Test.truthy(not Areas.canEnter(d, "Legendary"))
	d.passes.AllAreas = true
	Test.eq(Areas.refreshUnlocks(Config, d), { "SuperRare", "Legendary" })
	Test.eq(Areas.unlockReason(def("Common"), fresh()), "free")
	Test.eq(Areas.unlockReason(def("Mythic"), fresh()), nil)
end)

Test.case("unlocks are permanent: they survive loading, and a later rebirth reset does not relock them", function()
	local d = fresh()
	d.rebirths = 6
	Areas.refreshUnlocks(Config, d)
	d.rebirths = 0 -- as Apex will do later (spec: unlocks are kept)
	Test.truthy(Areas.canEnter(d, "Mythic"))
	local loaded = Profile.load(d, Config)
	Test.truthy(Areas.canEnter(loaded, "Mythic") and Areas.canEnter(loaded, "SuperRare"))
	Test.eq(loaded.areas, d.areas)
end)

Test.case("a save cannot invent an area that does not exist", function()
	local loaded = Profile.load({ areas = { Atlantis = true, Common = "yes" } }, Config)
	Test.eq(loaded.areas.Atlantis, nil)
	Test.truthy(not Areas.canEnter(loaded, "Mythic"))
end)

Test.case("locked hint tells the player how to get in", function()
	Test.eq(Areas.lockedHint(def("SuperRare")), "SuperRare is locked: reach Rebirth 2 or buy early access")
end)

Test.case("the 8 species per area are all in the part table, 48 in total", function()
	local species: { [string]: number } = {}
	for _, p in Parts.all() do
		species[p.area] = (species[p.area] or 0) + (if p.slot == "Head" then 1 else 0)
	end
	local total = 0
	for _, d in Config.Areas do
		Test.eq(species[d.name], 8, d.name)
		total += species[d.name]
	end
	Test.eq(total, 48)
end)

Test.done()
