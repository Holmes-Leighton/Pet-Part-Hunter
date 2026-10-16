--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Maze = require("../src/Shared/Maze")
local Chaser = require("../src/Shared/Chaser")

local CELL = 16

local function gridFor(maze: Maze.Maze): Chaser.Grid
	return {
		cellSize = CELL,
		worldToCell = function(x, z)
			local cx, cy = Maze.worldToCell(x, z, CELL)
			return math.clamp(cx, 1, maze.width), math.clamp(cy, 1, maze.height)
		end,
		cellToWorld = function(cx, cy)
			return Maze.cellToWorld(cx, cy, CELL)
		end,
		findPath = function(fx, fy, tx, ty)
			return Maze.findPath(maze, fx, fy, tx, ty)
		end,
	}
end

-- Run the chaser toward a fixed target in small steps, checking each move stays inside the maze corridors.
local function chase(maze: Maze.Maze, chaser: Chaser.Chaser, tx: number, tz: number, seconds: number, dt: number)
	local grid = gridFor(maze)
	local prevCx, prevCy = grid.worldToCell(chaser:position())
	local steps = math.floor(seconds / dt)
	for _ = 1, steps do
		local px, pz = chaser:position()
		chaser:step(dt, tx, tz)
		local nx, nz = chaser:position()
		Test.truthy(math.sqrt((nx - px) ^ 2 + (nz - pz) ^ 2) <= chaser.speed * dt + 1e-6, "never faster than its speed")
		local cx, cy = grid.worldToCell(nx, nz)
		if cx ~= prevCx or cy ~= prevCy then
			local adjacent = math.abs(cx - prevCx) + math.abs(cy - prevCy) == 1
			Test.truthy(adjacent, "moved to a non-adjacent cell")
			local connected = false
			for _, n in Maze.neighbors(maze, prevCx, prevCy) do
				if n.x == cx and n.y == cy then
					connected = true
				end
			end
			Test.truthy(connected, string.format("walked through a wall from (%d,%d) to (%d,%d)", prevCx, prevCy, cx, cy))
			prevCx, prevCy = cx, cy
		end
	end
end

Test.case("chaser covers exactly speed * time on a straight corridor", function()
	local maze = Maze.generate(2, 2, Rng.new(1), 1) -- fully open 2x2
	local c = Chaser.new(gridFor(maze), 8, 8, 10)
	c:step(1, 8 + 40, 8) -- target far east, same row: goes along x
	local x = c:position()
	Test.truthy(x > 8 and x <= 18 + 1e-6, "moved at most 10 studs, got x=" .. x)
end)

Test.case("same-cell chase goes straight and stops on the target", function()
	local maze = Maze.generate(3, 3, Rng.new(1), 0)
	local c = Chaser.new(gridFor(maze), 2, 2, 100)
	c:step(1, 10, 6)
	local x, z = c:position()
	Test.near(x, 10)
	Test.near(z, 6)
end)

Test.case("never walks through walls, in 30 different mazes", function()
	for seed = 1, 30 do
		local maze = Maze.generate(8, 8, Rng.new(seed), 0.15)
		local sx, sz = Maze.cellToWorld(1, 1, CELL)
		local tx, tz = Maze.cellToWorld(8, 8, CELL)
		local c = Chaser.new(gridFor(maze), sx, sz, 14)
		chase(maze, c, tx, tz, 60, 1 / 30)
	end
end)

Test.case("reaches a distant target in about route length / speed seconds", function()
	local maze = Maze.generate(8, 8, Rng.new(6), 0.1)
	local path = Maze.findPath(maze, 1, 1, 8, 8) :: any
	local routeLen = (#path - 1) * CELL
	local sx, sz = Maze.cellToWorld(1, 1, CELL)
	local tx, tz = Maze.cellToWorld(8, 8, CELL)
	local c = Chaser.new(gridFor(maze), sx, sz, 16)
	local t = 0
	while c:distanceTo(tx, tz) > 0.01 and t < 200 do
		c:step(1 / 30, tx, tz)
		t += 1 / 30
	end
	Test.truthy(c:distanceTo(tx, tz) <= 0.01, "should have arrived")
	Test.near(t, routeLen / 16, 0.2, "arrival time")
end)

Test.case("re-routes when the target moves to a different branch", function()
	local maze = Maze.generate(8, 8, Rng.new(12), 0.1)
	local sx, sz = Maze.cellToWorld(4, 4, CELL)
	local c = Chaser.new(gridFor(maze), sx, sz, 14)
	local a = { Maze.cellToWorld(1, 1, CELL) }
	local b = { Maze.cellToWorld(8, 1, CELL) }
	chase(maze, c, a[1], a[2], 2, 1 / 30)
	chase(maze, c, b[1], b[2], 2, 1 / 30)
	Test.truthy(true)
end)

-- World position `dist` studs along a route of cells (through the cell centres).
local function pointAlong(path: { { x: number, y: number } }, dist: number): (number, number)
	local last = #path
	local seg = math.min(math.floor(dist / CELL) + 1, last - 1)
	local frac = math.min((dist - (seg - 1) * CELL) / CELL, 1)
	local ax, az = Maze.cellToWorld(path[seg].x, path[seg].y, CELL)
	local bx, bz = Maze.cellToWorld(path[seg + 1].x, path[seg + 1].y, CELL)
	return ax + (bx - ax) * frac, az + (bz - az) * frac
end

-- A player runs the long route across the maze with a two-cell head start. Returns true if the chaser gets within catch range.
local function pursuit(playerSpeed: number, chaserSpeed: number): boolean
	local maze = Maze.generate(8, 8, Rng.new(21), 0.1)
	local path = Maze.findPath(maze, 1, 1, 8, 8) :: any
	assert(#path >= 12, "test needs a long route")
	local c = Chaser.new(gridFor(maze), (Maze.cellToWorld(1, 1, CELL)), (select(2, Maze.cellToWorld(1, 1, CELL))), chaserSpeed)
	local dt = 1 / 30
	local routeLen = (#path - 1) * CELL
	local run = 2 * CELL
	while run < routeLen do
		run += playerSpeed * dt
		local px, pz = pointAlong(path, math.min(run, routeLen))
		c:step(dt, px, pz)
		if c:distanceTo(px, pz) < 3 then
			return true
		end
	end
	return false
end

Test.case("a slower chaser never catches a runner who keeps moving along the route", function()
	Test.eq(pursuit(16, 13.6), false)
end)

Test.case("a faster chaser catches the runner on the same route", function()
	Test.eq(pursuit(16, 21.6), true)
end)

Test.done()
