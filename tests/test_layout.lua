--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Maze = require("../src/Shared/Maze")
local AreaLayout = require("../src/Shared/AreaLayout")

local OPTS: AreaLayout.Options = { exitCount = 3, spawnCount = 24, minExitSeparation = 8 }

local function build(seed: number)
	local maze = Maze.generate(11, 11, Rng.new(seed), 0.12)
	return maze, AreaLayout.generate(Maze, maze, Rng.new(seed + 1000), OPTS)
end

local function same(a: AreaLayout.Cell, b: AreaLayout.Cell): boolean
	return a.x == b.x and a.y == b.y
end

Test.case("distances: start is 0, neighbours are 1, everything is reachable", function()
	local m = Maze.generate(6, 6, Rng.new(1), 0.1)
	local d = Maze.distances(m, 1, 1)
	Test.eq(d[1], 0)
	for _, n in Maze.neighbors(m, 1, 1) do
		Test.eq(d[(n.y - 1) * 6 + n.x], 1)
	end
	local count = 0
	for _ in d do
		count += 1
	end
	Test.eq(count, 36)
end)

Test.case("distances agree with findPath lengths", function()
	local m = Maze.generate(8, 8, Rng.new(2), 0.2)
	local d = Maze.distances(m, 3, 3)
	for y = 1, 8 do
		for x = 1, 8 do
			Test.eq(d[(y - 1) * 8 + x], #(Maze.findPath(m, 3, 3, x, y) :: any) - 1)
		end
	end
end)

Test.case("entrance is the corner and the chaser starts at the far end", function()
	for seed = 1, 15 do
		local maze, layout = build(seed)
		Test.eq(layout.entrance, { x = 1, y = 1 })
		local d = Maze.distances(maze, 1, 1)
		local best = 0
		for _, v in d do
			best = math.max(best, v)
		end
		Test.eq(d[(layout.chaserStart.y - 1) * 11 + layout.chaserStart.x], best, "chaser start is at maximum distance")
	end
end)

Test.case("every exit is a junction, never a dead end, and far from the entrance", function()
	for seed = 1, 25 do
		local maze, layout = build(seed)
		Test.truthy(#layout.exits >= 2, "seed " .. seed .. " gave " .. #layout.exits .. " exits")
		local d = Maze.distances(maze, 1, 1)
		for _, e in layout.exits do
			Test.truthy(#Maze.neighbors(maze, e.x, e.y) >= 3, "exit not a junction")
			Test.truthy(d[(e.y - 1) * 11 + e.x] >= OPTS.minExitSeparation, "exit too close to entrance")
		end
	end
end)

Test.case("exits are spread out from each other", function()
	for seed = 1, 25 do
		local maze, layout = build(seed)
		for i, a in layout.exits do
			local d = Maze.distances(maze, a.x, a.y)
			for j, b in layout.exits do
				if i ~= j then
					Test.truthy(d[(b.y - 1) * 11 + b.x] >= OPTS.minExitSeparation, "exits too close")
				end
			end
		end
	end
end)

Test.case("spawn cells are distinct and avoid the entrance, exits and chaser start", function()
	for seed = 1, 15 do
		local _, layout = build(seed)
		Test.eq(#layout.spawnCells, OPTS.spawnCount)
		for i, c in layout.spawnCells do
			Test.truthy(not same(c, layout.entrance) and not same(c, layout.chaserStart), "spawn on a reserved cell")
			for _, e in layout.exits do
				Test.truthy(not same(c, e), "spawn on an exit")
			end
			for j = i + 1, #layout.spawnCells do
				Test.truthy(not same(c, layout.spawnCells[j]), "two spawns on one cell")
			end
		end
	end
end)

Test.case("layout is reproducible from the seed", function()
	local _, a = build(7)
	local _, b = build(7)
	Test.eq(a, b)
end)

Test.done()
