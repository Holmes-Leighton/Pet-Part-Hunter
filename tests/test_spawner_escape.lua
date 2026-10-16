--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local PartSpawner = require("../src/Shared/PartSpawner")
local EscapeTimer = require("../src/Shared/EscapeTimer")

local CATALOG: { PartSpawner.Template } = {
	{ species = "Chicken", slot = "Head", rarity = "Common" },
	{ species = "Tiger", slot = "Legs", rarity = "Common" },
	{ species = "Frog", slot = "Tail", rarity = "Common", weight = 2 },
}

local function points(n: number)
	local out = {}
	for i = 1, n do
		table.insert(out, { x = i * 10, z = i * 5 })
	end
	return out
end

Test.case("spawner fills the active count on distinct points", function()
	local s = PartSpawner.new(Rng.new(1), points(12), CATALOG, 5, 20)
	local spawns = s:activeSpawns()
	Test.eq(#spawns, 5)
	local seen: { [number]: boolean } = {}
	for _, sp in spawns do
		Test.truthy(not seen[sp.pointIndex], "two parts on one point")
		seen[sp.pointIndex] = true
	end
end)

Test.case("every spawned part has a unique id", function()
	local s = PartSpawner.new(Rng.new(2), points(12), CATALOG, 8, 20)
	local ids: { [string]: boolean } = {}
	for _, sp in s:activeSpawns() do
		Test.truthy(not ids[sp.part.id], "duplicate part id")
		ids[sp.part.id] = true
	end
end)

Test.case("first claim wins, second claim of the same part gets nothing", function()
	local s = PartSpawner.new(Rng.new(3), points(12), CATALOG, 5, 20)
	local id = s:activeSpawns()[1].spawnId
	Test.truthy(s:claim(id))
	Test.eq(s:claim(id), nil)
	Test.eq(#s:activeSpawns(), 4)
end)

Test.case("a taken part respawns after the timer, at a different point", function()
	local s = PartSpawner.new(Rng.new(4), points(12), CATALOG, 5, 20)
	local first = s:activeSpawns()[1]
	s:claim(first.spawnId)
	s:update(19)
	Test.eq(#s:activeSpawns(), 4, "not yet")
	s:update(1.5)
	local spawns = s:activeSpawns()
	Test.eq(#spawns, 5, "respawned")
	for _, sp in spawns do
		Test.truthy(sp.spawnId ~= first.spawnId, "new spawn has a new id")
	end
end)

Test.case("respawn avoids the point it was just taken from when others are free", function()
	for seed = 1, 40 do
		local s = PartSpawner.new(Rng.new(seed), points(12), CATALOG, 5, 1)
		local first = s:activeSpawns()[1]
		s:claim(first.spawnId)
		s:update(2)
		for _, sp in s:activeSpawns() do
			Test.truthy(sp.pointIndex ~= first.pointIndex or false, "respawned on the same point (seed " .. seed .. ")")
		end
	end
end)

Test.case("never more active parts than the count, even after many claims", function()
	local s = PartSpawner.new(Rng.new(5), points(7), CATALOG, 5, 2)
	for _ = 1, 50 do
		for _, sp in s:activeSpawns() do
			s:claim(sp.spawnId)
		end
		s:update(3)
		Test.truthy(#s:activeSpawns() <= 5)
	end
end)

Test.case("part choice follows the weights", function()
	local counts: { [string]: number } = { Chicken = 0, Tiger = 0, Frog = 0 }
	local s = PartSpawner.new(Rng.new(6), points(30), CATALOG, 1, 0.01)
	for _ = 1, 3000 do
		local sp = s:activeSpawns()[1]
		counts[sp.part.species] += 1
		s:claim(sp.spawnId)
		s:update(0.02)
	end
	Test.truthy(counts.Frog > counts.Chicken * 1.5 and counts.Frog > counts.Tiger * 1.5, "Frog has twice the weight")
end)

Test.case("escape completes after exactly the hold time", function()
	local t = EscapeTimer.new(2)
	Test.near(t:update(1, true, false), 0.5)
	Test.truthy(not t:isDone())
	Test.near(t:update(1, true, false), 1)
	Test.truthy(t:isDone())
end)

Test.case("leaving the point or being interrupted resets progress", function()
	local t = EscapeTimer.new(2)
	t:update(1.5, true, false)
	Test.eq(t:update(0.1, false, false), 0)
	t:update(1.5, true, false)
	Test.eq(t:update(0.1, true, true), 0)
	Test.truthy(not t:isDone())
	t:update(2, true, false)
	Test.truthy(t:isDone())
end)

Test.case("once done it stays done until reset", function()
	local t = EscapeTimer.new(2)
	t:update(2, true, false)
	t:update(1, false, true)
	Test.truthy(t:isDone())
	t:reset()
	Test.truthy(not t:isDone())
	Test.eq(t:progress(), 0)
end)

Test.done()
