--!strict
local Test = require("./harness")
local Support = require("./support")
local Rng = require("../src/Shared/Rng")
local Maze = require("../src/Shared/Maze")
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

-- Build a run on an 8x8 maze: player enters at cell (1,1), chaser starts in the far corner, exit in cell (1,2).
local function setup(chaserSpeed: number, capacity: number?)
	local maze = Maze.generate(8, 8, Rng.new(33), 0.12)
	local grid = Support.gridFor(maze, CELL)
	local points = {}
	for y = 1, 8 do
		for x = 1, 8 do
			if x + y > 4 then
				local wx, wz = Maze.cellToWorld(x, y, CELL)
				table.insert(points, { x = wx, z = wz })
			end
		end
	end
	local spawner = PartSpawner.new(Rng.new(8), points, { { species = "Chicken", slot = "Head", rarity = "Common" } }, 5, Config.Parts.RespawnSeconds)
	local cx, cz = Maze.cellToWorld(8, 8, CELL)
	local ex, ez = Maze.cellToWorld(1, 2, CELL)
	local settings = table.clone(SETTINGS) -- per run: some tests change settings
	local run = Run.new({
		bag = Bag.new(capacity or 3),
		chaser = Chaser.new(grid, cx, cz, chaserSpeed),
		spawner = spawner,
		timer = EscapeTimer.new(Config.Escape.HoldSeconds),
	}, { { x = ex, z = ez, radius = Config.Escape.ZoneRadius } }, settings, { x = cx, z = cz })
	return run, spawner, maze, { ex = ex, ez = ez }
end

local function tickFor(run: Run.Run, seconds: number, px: number, pz: number): { Run.Event }
	local all = {}
	for _ = 1, math.floor(seconds / DT) do
		for _, e in run:update(DT, px, pz) do
			table.insert(all, e)
		end
	end
	return all
end

local function pickUp(run: Run.Run, spawner: PartSpawner.PartSpawner, n: number)
	local got = 0
	for _, sp in spawner:activeSpawns() do
		if got >= n then
			break
		end
		local point = spawner:pointOf(sp.spawnId) :: any
		if run:tryPickup(sp.spawnId, point.x, point.z) then
			got += 1
		end
	end
	return got
end

Test.case("player starts protected with the chaser waiting at its start", function()
	local run = setup(13.6)
	Test.truthy(run:isProtected())
end)

Test.case("picking up needs range, claims the part once, and respects bag size", function()
	local run, spawner = setup(13.6)
	local sp = spawner:activeSpawns()[1]
	local p = spawner:pointOf(sp.spawnId) :: any
	local ok, why = run:tryPickup(sp.spawnId, p.x + 50, p.z)
	Test.eq(ok, false)
	Test.eq(why, "too-far")
	Test.truthy(run:tryPickup(sp.spawnId, p.x, p.z))
	Test.eq(run.bag:count(), 1)
	local ok2, why2 = run:tryPickup(sp.spawnId, p.x, p.z)
	Test.eq(ok2, false)
	Test.eq(why2, "gone")
end)

Test.case("a full bag does not waste the part on the floor", function()
	local run, spawner = setup(13.6, 3)
	Test.eq(pickUp(run, spawner, 3), 3)
	local remaining = spawner:activeSpawns()
	Test.eq(#remaining, 2)
	local p = spawner:pointOf(remaining[1].spawnId) :: any
	local ok, why = run:tryPickup(remaining[1].spawnId, p.x, p.z)
	Test.eq(ok, false)
	Test.eq(why, "full")
	Test.eq(#spawner:activeSpawns(), 2, "still there for someone else")
end)

Test.case("escaping banks the bag: holding the exit for 2 seconds", function()
	local run, spawner, _, exit = setup(13.6)
	pickUp(run, spawner, 3)
	local events = tickFor(run, 1, exit.ex, exit.ez)
	Test.eq(#events, 0, "not yet after 1 second")
	events = tickFor(run, 1.2, exit.ex, exit.ez)
	Test.eq(#events, 1)
	local e = events[1] :: any
	Test.eq(e.type, "escaped")
	Test.eq(#e.parts, 3)
	Test.eq(run.bag:count(), 0)
end)

Test.case("stepping off the exit before 2 seconds cancels the escape", function()
	local run, spawner, _, exit = setup(0)
	pickUp(run, spawner, 2)
	Test.eq(#tickFor(run, 1.5, exit.ex, exit.ez), 0)
	Test.eq(#tickFor(run, 0.2, exit.ex + 40, exit.ez), 0)
	Test.eq(#tickFor(run, 1.5, exit.ex, exit.ez), 0, "needs a fresh 2 seconds")
	Test.eq(#tickFor(run, 1, exit.ex, exit.ez), 1)
end)

Test.case("a chaser reaching the player drops the bag and sends them back to start", function()
	local run, spawner, _, exit = setup(30)
	pickUp(run, spawner, 3)
	local events = tickFor(run, 30, exit.ex + 60, exit.ez + 40) -- standing in a corridor away from the exit
	local caught
	for _, e in events do
		if e.type == "caught" and caught == nil then
			caught = e
		end
	end
	Test.truthy(caught, "expected to be caught")
	Test.eq(#(caught :: any).lost, 3)
	Test.eq(run.bag:count(), 0)
end)

Test.case("after being caught the player is protected and the chaser goes back to its start", function()
	local run, spawner = setup(60)
	pickUp(run, spawner, 1)
	local events: { Run.Event } = {}
	local t = 0
	while #events == 0 and t < 60 do
		events = run:update(DT, 24, 24)
		t += DT
	end
	Test.eq((events[1] :: any).type, "caught")
	Test.truthy(run:isProtected())
	local x, z = run.chaser:position()
	local cx, cz = Maze.cellToWorld(8, 8, CELL)
	Test.near(x, cx)
	Test.near(z, cz)
	-- Protected player standing right on the chaser start cannot be re-caught instantly.
	Test.eq(#run:update(DT, cx, cz), 0)
end)

Test.case("the chaser waits during the head start and does not move or catch", function()
	local run = setup(60)
	local x0, z0 = run.chaser:position()
	tickFor(run, Config.Chase.HeadStartSeconds - 0.1, x0, z0)
	local x1, z1 = run.chaser:position()
	Test.near(x1, x0)
	Test.near(z1, z0)
end)

Test.case("a chaser coming close interrupts the escape hold", function()
	-- Chaser sits next to the exit and cannot catch (radius 0 would be silly, so use a big interrupt range instead).
	local run, _, _, exit = setup(0)
	run.settings.interruptDistance = 5000
	run.settings.catchRadius = 0
	run.chaser:teleport(exit.ex, exit.ez)
	tickFor(run, Config.Chase.ProtectionSeconds + Config.Chase.HeadStartSeconds + 0.1, exit.ex, exit.ez)
	Test.eq(#tickFor(run, 5, exit.ex, exit.ez), 0, "interrupted the whole time")
end)

Test.case("after escaping, further updates do nothing", function()
	local run, _, _, exit = setup(13.6)
	tickFor(run, 3, exit.ex, exit.ez)
	Test.eq(run.state, "escaped")
	Test.eq(#tickFor(run, 5, exit.ex, exit.ez), 0)
	local ok, why = run:tryPickup(1, 0, 0)
	Test.eq(ok, false)
	Test.eq(why, "not-running")
end)

Test.case("full playthrough: a runner at the expected speed escapes a Common chaser", function()
	local run, spawner, maze, _ = setup(Config.Player.WalkSpeed * Config.Chase.SpeedMultiplier.Common)
	-- Player walks cell to cell from (1,1) to a part, then to the exit, at full walk speed.
	local function walkTo(path: { { x: number, y: number } }, px: number, pz: number): (number, number)
		for i = 2, #path do
			local tx, tz = Maze.cellToWorld(path[i].x, path[i].y, CELL)
			while math.abs(px - tx) + math.abs(pz - tz) > 0.01 do
				local dx, dz = tx - px, tz - pz
				local d = math.sqrt(dx * dx + dz * dz)
				local step = math.min(d, Config.Player.WalkSpeed * DT)
				px += dx / d * step
				pz += dz / d * step
				for _, e in run:update(DT, px, pz) do
					Test.truthy(e.type ~= "caught", "was caught while running the route")
				end
			end
		end
		return px, pz
	end
	local px, pz = Maze.cellToWorld(1, 1, CELL)
	local target = spawner:activeSpawns()[1]
	local tp = spawner:pointOf(target.spawnId) :: any
	local tcx, tcy = Maze.worldToCell(tp.x, tp.z, CELL)
	px, pz = walkTo(Maze.findPath(maze, 1, 1, tcx, tcy) :: any, px, pz)
	Test.truthy(run:tryPickup(target.spawnId, px, pz), "picked up the part")
	px, pz = walkTo(Maze.findPath(maze, tcx, tcy, 1, 2) :: any, px, pz)
	local escaped = false
	for _, e in tickFor(run, 3, px, pz) do
		if e.type == "escaped" then
			escaped = true
			Test.eq(#(e.parts :: { any }), 1)
		end
	end
	Test.truthy(escaped, "escaped with the part")
end)

Test.done()
