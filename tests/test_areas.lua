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

Test.case("part pools: each area hunts its own rarity, lower areas mix in the tier below, Special parts drift in", function()
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
	local common = Areas.templates(Config, def("Common"))
	Test.truthy(share(common, "Common") > 0.9, "Common area is mostly Common parts")
	local unc = Areas.templates(Config, def("Uncommon"))
	Test.truthy(share(unc, "Uncommon") > 0.6 and share(unc, "Common") > 0.05, "Uncommon: Uncommon plus some Common")
	local rare = Areas.templates(Config, def("Rare"))
	Test.truthy(share(rare, "Rare") > 0.6 and share(rare, "Uncommon") > 0.05, "Rare: Rare plus some Uncommon")
	local mythic = Areas.templates(Config, def("Mythic"))
	Test.truthy(share(mythic, "Mythic") > 0.7, "Mythic: mostly Mythic")
	local specials = 0
	for _, t in mythic do
		if t.rarity ~= "Mythic" then
			Test.eq(t.slot, "Special", "only Special parts come from other areas")
			specials += 1
		end
	end
	Test.eq(specials, 40, "Special parts of the 5 other areas (8 species each)")
	for _, t in rare do
		Test.truthy(Parts.get(t.species .. "_" .. t.slot) ~= nil, "template maps to a catalog part")
	end
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
