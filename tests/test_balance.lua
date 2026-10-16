--!strict
-- Balance check per area (spec section 4): with the shipped Config, can a player running a perfect route at the
-- area's expected speed grab a part and escape that area's chaser? Higher areas are meant to be harder, not impossible:
-- "players at the expected speed can escape with good routing, while under-levelled players get caught".
local Test = require("./harness")
local Support = require("./support")
local Rng = require("../src/Shared/Rng")
local Maze = require("../src/Shared/Maze")
local Areas = require("../src/Shared/Areas")
local Bag = require("../src/Shared/Bag")
local Chaser = require("../src/Shared/Chaser")
local EscapeTimer = require("../src/Shared/EscapeTimer")
local PartSpawner = require("../src/Shared/PartSpawner")
local Run = require("../src/Shared/Run")
local Config = require("../src/Shared/Config")

local CELL = Config.Maze.CellSize
local DT = 1 / 30

local SETTINGS: Run.Settings = {
	catchRadius = Config.Chase.CatchRadius,
	protectionSeconds = Config.Chase.ProtectionSeconds,
	headStartSeconds = Config.Chase.HeadStartSeconds,
	interruptDistance = Config.Chase.InterruptDistance,
	pickupRadius = Config.Parts.PickupRadius,
}

local function withSeed(def: Areas.Def, seed: number): Areas.Def
	local copy: any = table.clone(def)
	copy.seed = seed
	return copy
end

-- Play one plan: entrance -> the part in spawn slot `spawnIndex` -> exit `exitIndex`.
-- Returns "escaped", "escaped-empty", "caught" or "timeout". `chaserSpeed` overrides the area's chaser (0 = frozen).
local function play(def: Areas.Def, spawnIndex: number, exitIndex: number, chaserSpeed: number?): string
	local maze, layout = Areas.generate(Config, def)
	local points: { PartSpawner.Point } = {}
	for _, c in layout.spawnCells do
		local x, z = Maze.cellToWorld(c.x, c.y, CELL)
		table.insert(points, { x = x, z = z })
	end
	local spawner = PartSpawner.new(Rng.new(def.seed + 2), points, Areas.templates(Config, def), def.activeParts, Config.Parts.RespawnSeconds)
	local target = spawner:activeSpawns()[spawnIndex]
	local tp = points[target.pointIndex]
	local tcx, tcy = Maze.worldToCell(tp.x, tp.z, CELL)
	local exit = layout.exits[exitIndex]

	local sx, sz = Maze.cellToWorld(layout.chaserStart.x, layout.chaserStart.y, CELL)
	local zones = {}
	for _, e in layout.exits do
		local x, z = Maze.cellToWorld(e.x, e.y, CELL)
		table.insert(zones, { x = x, z = z, radius = Config.Escape.ZoneRadius })
	end
	local run = Run.new({
		bag = Bag.new(Config.Bag.StartCapacity),
		chaser = Chaser.new(Support.gridFor(maze, CELL), sx, sz, chaserSpeed or Areas.chaserSpeed(Config, def)),
		spawner = spawner,
		timer = EscapeTimer.new(Config.Escape.HoldSeconds),
	}, zones, SETTINGS, { x = sx, z = sz })

	local route = Maze.findPath(maze, 1, 1, tcx, tcy) :: { { x: number, y: number } }
	local leg2 = Maze.findPath(maze, tcx, tcy, exit.x, exit.y) :: { { x: number, y: number } }
	for i = 2, #leg2 do
		table.insert(route, leg2[i])
	end

	local px, pz = Maze.cellToWorld(1, 1, CELL)
	local picked = false
	local idx = 2
	for _ = 1, 30 * 240 do
		if idx <= #route then
			local wx, wz = Maze.cellToWorld(route[idx].x, route[idx].y, CELL)
			local dx, dz = wx - px, wz - pz
			local d = math.sqrt(dx * dx + dz * dz)
			local step = def.expectedWalk * DT
			if d <= step then
				px, pz = wx, wz
				idx += 1
			else
				px += dx / d * step
				pz += dz / d * step
			end
		end
		if not picked and run:tryPickup(target.spawnId, px, pz) then
			picked = true
		end
		for _, e in run:update(DT, px, pz) do
			if e.type == "caught" then
				return "caught"
			elseif e.type == "escaped" then
				return if picked then "escaped" else "escaped-empty"
			end
		end
	end
	return "timeout"
end

local function winners(def: Areas.Def, chaserSpeed: number?): (number, number)
	local _, layout = Areas.generate(Config, def)
	local won, total = 0, 0
	for s = 1, def.activeParts do
		for e = 1, #layout.exits do
			total += 1
			if play(def, s, e, chaserSpeed) == "escaped" then
				won += 1
			end
		end
	end
	return won, total
end

Test.case("simulation sanity: with a frozen chaser every plan in every area escapes", function()
	for _, def in Config.Areas do
		local won, total = winners(def, 0)
		Test.eq(won, total, def.name)
	end
end)

Test.case("every shipped area is winnable by a perfect runner at its expected speed", function()
	for _, def in Config.Areas do
		local won, total = winners(def)
		print(string.format("        %-10s shipped seed: %d of %d plans escape", def.name, won, total))
		Test.truthy(won >= 1, def.name .. ": no winnable plan for the shipped seed")
	end
end)

Test.case("a player 25% slower than expected is caught more often than one at the expected speed", function()
	local fastWins, slowWins = 0, 0
	for _, def in Config.Areas do
		local base = Areas.chaserSpeed(Config, def)
		local slow: any = table.clone(def)
		slow.expectedWalk = def.expectedWalk * 0.75
		-- Same chaser speed as the real area, slower runner.
		local w1 = winners(def)
		local w2 = winners(slow, base)
		fastWins += w1
		slowWins += w2
	end
	print(string.format("        plans won: expected speed %d, 25%% slower %d", fastWins, slowWins))
	Test.truthy(slowWins < fastWins, "under-levelled players should be caught more")
end)

Test.case("difficulty rises with the area tier (the share of winning plans never jumps up)", function()
	local prev = 2.0
	for _, def in Config.Areas do
		local seeds, winnable, plansWon, plansTotal = 8, 0, 0, 0
		for seed = 1, seeds do
			local won, total = winners(withSeed(def, 100 + seed))
			if won >= 1 then
				winnable += 1
			end
			plansWon += won
			plansTotal += total
		end
		local share = plansWon / plansTotal
		print(string.format("        %-10s %2d/%d seeds winnable; %3.0f%% of plans escape", def.name, winnable, seeds, share * 100))
		Test.truthy(winnable >= 1, def.name .. " is never winnable")
		Test.truthy(share < 1, def.name .. " should still catch a careless player")
		Test.truthy(share <= prev + 0.15, def.name .. " is much easier than the tier below")
		prev = share
	end
end)

Test.done()
