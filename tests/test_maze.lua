--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Maze = require("../src/Shared/Maze")

Test.case("rng is deterministic per seed", function()
	local a, b = Rng.new(42), Rng.new(42)
	for _ = 1, 20 do
		Test.eq(a:next(), b:next())
	end
	Test.truthy(Rng.new(1):next() ~= Rng.new(2):next(), "different seeds differ")
end)

Test.case("rng int stays in range and shuffle keeps the elements", function()
	local r = Rng.new(7)
	for _ = 1, 500 do
		local v = r:int(3, 6)
		Test.truthy(v >= 3 and v <= 6 and v == math.floor(v), "int in [3,6]")
	end
	local list = { 1, 2, 3, 4, 5, 6, 7, 8 }
	r:shuffle(list)
	table.sort(list)
	Test.eq(list, { 1, 2, 3, 4, 5, 6, 7, 8 })
end)

Test.case("same seed gives the same maze", function()
	local a = Maze.generate(9, 9, Rng.new(5), 0.2)
	local b = Maze.generate(9, 9, Rng.new(5), 0.2)
	Test.eq(a.cells, b.cells)
end)

Test.case("every cell can reach every other cell", function()
	for seed = 1, 20 do
		local m = Maze.generate(10, 8, Rng.new(seed), 0.15)
		for y = 1, m.height do
			for x = 1, m.width do
				Test.truthy(Maze.findPath(m, 1, 1, x, y), string.format("seed %d: (%d,%d) unreachable", seed, x, y))
			end
		end
	end
end)

Test.case("passages are symmetric (open both ways)", function()
	local m = Maze.generate(8, 8, Rng.new(3), 0.3)
	for y = 1, m.height do
		for x = 1, m.width do
			for _, n in Maze.neighbors(m, x, y) do
				local back = false
				for _, nn in Maze.neighbors(m, n.x, n.y) do
					if nn.x == x and nn.y == y then
						back = true
					end
				end
				Test.truthy(back, string.format("(%d,%d)->(%d,%d) not symmetric", x, y, n.x, n.y))
			end
		end
	end
end)

Test.case("outer border is closed", function()
	local m = Maze.generate(7, 7, Rng.new(9), 1)
	for i = 1, 7 do
		Test.truthy(not Maze.isOpen(m, i, 1, Maze.N))
		Test.truthy(not Maze.isOpen(m, i, 7, Maze.S))
		Test.truthy(not Maze.isOpen(m, 1, i, Maze.W))
		Test.truthy(not Maze.isOpen(m, 7, i, Maze.E))
	end
end)

Test.case("zero loop fraction gives a perfect maze, more loops adds cycles", function()
	local perfect = Maze.generate(10, 10, Rng.new(11), 0)
	Test.eq(Maze.cycleCount(perfect), 0)
	local loopy = Maze.generate(10, 10, Rng.new(11), 0.2)
	Test.truthy(Maze.cycleCount(loopy) > 5, "expected several loops, got " .. Maze.cycleCount(loopy))
end)

Test.case("findPath returns a connected route with both ends", function()
	local m = Maze.generate(8, 8, Rng.new(4), 0.1)
	local p = Maze.findPath(m, 1, 1, 8, 8) :: any
	Test.eq(p[1], { x = 1, y = 1 })
	Test.eq(p[#p], { x = 8, y = 8 })
	for i = 2, #p do
		local dx = math.abs(p[i].x - p[i - 1].x)
		local dy = math.abs(p[i].y - p[i - 1].y)
		Test.eq(dx + dy, 1, "steps are one cell")
	end
	Test.eq(#(Maze.findPath(m, 3, 3, 3, 3) :: any), 1)
	Test.eq(Maze.findPath(m, 1, 1, 99, 99), nil)
end)

Test.case("findPath takes the shorter way around a loop", function()
	-- A 2x2 ring with all four passages open: (1,1)->(2,2) is 3 cells either way, never 4.
	local m = Maze.generate(2, 2, Rng.new(1), 1)
	Test.eq(Maze.cycleCount(m), 1)
	Test.eq(#(Maze.findPath(m, 1, 1, 2, 2) :: any), 3)
end)

Test.case("world <-> cell conversion round trips and centres cells", function()
	local wx, wz = Maze.cellToWorld(3, 2, 16)
	Test.eq({ wx, wz }, { 40, 24 })
	Test.eq({ Maze.worldToCell(wx, wz, 16) }, { 3, 2 })
	Test.eq({ Maze.worldToCell(0.1, 0.1, 16) }, { 1, 1 })
end)

Test.case("dead ends exist and have exactly one exit", function()
	local m = Maze.generate(10, 10, Rng.new(8), 0.1)
	local ends = Maze.deadEnds(m)
	Test.truthy(#ends > 0)
	for _, c in ends do
		Test.eq(#Maze.neighbors(m, c.x, c.y), 1)
	end
end)

Test.done()
