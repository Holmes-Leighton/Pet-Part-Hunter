--!strict
-- Balance check: with the shipped Config, can a player running a perfect route at the expected speed
-- grab a part and escape the Common chaser? (spec section 4: "players at the expected speed can escape with good routing")
local Test = require("./harness")
local Support = require("./support")
local Rng = require("../src/Shared/Rng")
local Maze = require("../src/Shared/Maze")
local AreaLayout = require("../src/Shared/AreaLayout")
local Bag = require("../src/Shared/Bag")
local Chaser = require("../src/Shared/Chaser")
local EscapeTimer = require("../src/Shared/EscapeTimer")
local PartSpawner = require("../src/Shared/PartSpawner")
local Run = require("../src/Shared/Run")
local Config = require("../src/Shared/Config")

local CELL = Config.Maze.CellSize
local DT = 1 / 30

local CATALOG: { PartSpawner.Template } = {
	{ species = "Chicken", slot = "Head", rarity = "Common" },
	{ species = "Tiger", slot = "Legs", rarity = "Common" },
}

local function world(seed: number)
	local maze = Maze.generate(Config.Area.Width, Config.Area.Height, Rng.new(seed), Config.Maze.LoopFraction)
	local layout = AreaLayout.generate(Maze, maze, Rng.new(seed + 1), {
		exitCount = Config.Area.ExitCount,
		spawnCount = Config.Area.SpawnCells,
		minExitSeparation = Config.Area.MinExitSeparation,
	})
	return maze, layout
end

local SETTINGS: Run.Settings = {
	catchRadius = Config.Chase.CatchRadius,
	protectionSeconds = Config.Chase.ProtectionSeconds,
	headStartSeconds = Config.Chase.HeadStartSeconds,
	interruptDistance = Config.Chase.InterruptDistance,
	pickupRadius = Config.Parts.PickupRadius,
}

-- Play one plan: entrance -> the part in spawn slot `spawnIndex` -> exit `exitIndex`. Returns "escaped", "caught" or "timeout".
local function play(seed: number, spawnIndex: number, exitIndex: number, speedMult: number?): string
	local maze, layout = world(seed)
	local points: { PartSpawner.Point } = {}
	for _, c in layout.spawnCells do
		local x, z = Maze.cellToWorld(c.x, c.y, CELL)
		table.insert(points, { x = x, z = z })
	end
	local spawner = PartSpawner.new(Rng.new(seed + 2), points, CATALOG, Config.Parts.ActiveCount, Config.Parts.RespawnSeconds)
	local spawns = spawner:activeSpawns()
	local target = spawns[spawnIndex]
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
		chaser = Chaser.new(Support.gridFor(maze, CELL), sx, sz, Config.Player.WalkSpeed * (speedMult or Config.Chase.SpeedMultiplier.Common)),
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
	for _ = 1, 30 * 180 do
		if idx <= #route then
			local wx, wz = Maze.cellToWorld(route[idx].x, route[idx].y, CELL)
			local dx, dz = wx - px, wz - pz
			local d = math.sqrt(dx * dx + dz * dz)
			local step = Config.Player.WalkSpeed * DT
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

local function winners(seed: number, speedMult: number?): (number, number)
	local _, layout = world(seed)
	local won, total = 0, 0
	for s = 1, Config.Parts.ActiveCount do
		for e = 1, #layout.exits do
			total += 1
			if play(seed, s, e, speedMult) == "escaped" then
				won += 1
			end
		end
	end
	return won, total
end

Test.case("simulation sanity: a runner who stands still on an exit while the chaser is frozen escapes", function()
	-- Chaser speed 0 can never catch anyone, so every plan must end in a successful escape.
	local won, total = winners(Config.Area.Seed, 0)
	Test.eq(won, total)
end)

Test.case("the shipped Common area is winnable by a perfect runner (some part+exit plan escapes)", function()
	local won, total = winners(Config.Area.Seed)
	print(string.format("        seed %d: %d of %d plans escape", Config.Area.Seed, won, total))
	local _, layout = world(Config.Area.Seed)
	for sIdx = 1, Config.Parts.ActiveCount do
		for eIdx = 1, #layout.exits do
			local r = play(Config.Area.Seed, sIdx, eIdx)
			if r == "escaped" then
				print(string.format("        winning plan: part #%d then exit #%d", sIdx, eIdx))
			end
		end
	end
	Test.truthy(won >= 1, "no winnable plan for the shipped seed")
end)

Test.case("across many seeds most Common mazes have winnable plans, and not every plan is trivial", function()
	local seedsWithWin, plansWon, plansTotal = 0, 0, 0
	local seeds = 20
	for seed = 1, seeds do
		local won, total = winners(seed)
		if won >= 1 then
			seedsWithWin += 1
		end
		plansWon += won
		plansTotal += total
	end
	print(string.format("        %d/%d seeds winnable; %d/%d plans escape (%.0f%%)", seedsWithWin, seeds, plansWon, plansTotal, plansWon / plansTotal * 100))
	Test.truthy(seedsWithWin >= seeds * 0.8, "too many seeds have no winnable plan")
	Test.truthy(plansWon < plansTotal, "Common should still be able to catch a careless player")
end)

Test.done()
