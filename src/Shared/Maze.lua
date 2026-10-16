--!strict
-- Grid maze with loops. Each cell stores a bitmask of open sides, so the maze is easy to build, query and test.
-- Cell (1,1) is top-left; x grows east, y grows south. World space: cell (x,y) is centred at
-- ((x - 0.5) * cellSize, (y - 0.5) * cellSize) from the origin, with world Z following y.

local Maze = {}

export type Maze = {
	width: number,
	height: number,
	cells: { [number]: number }, -- index = (y - 1) * width + x
}

type Dir = { bit: number, opposite: number, dx: number, dy: number }

Maze.N = 1
Maze.E = 2
Maze.S = 4
Maze.W = 8

local DIRS: { Dir } = {
	{ bit = Maze.N, opposite = Maze.S, dx = 0, dy = -1 },
	{ bit = Maze.E, opposite = Maze.W, dx = 1, dy = 0 },
	{ bit = Maze.S, opposite = Maze.N, dx = 0, dy = 1 },
	{ bit = Maze.W, opposite = Maze.E, dx = -1, dy = 0 },
}

local function index(maze: Maze, x: number, y: number): number
	return (y - 1) * maze.width + x
end

function Maze.inBounds(maze: Maze, x: number, y: number): boolean
	return x >= 1 and y >= 1 and x <= maze.width and y <= maze.height
end

function Maze.isOpen(maze: Maze, x: number, y: number, bit: number): boolean
	if not Maze.inBounds(maze, x, y) then
		return false
	end
	return bit32.band(maze.cells[index(maze, x, y)], bit) ~= 0
end

local function carve(maze: Maze, x: number, y: number, dir: Dir)
	local a = index(maze, x, y)
	local b = index(maze, x + dir.dx, y + dir.dy)
	maze.cells[a] = bit32.bor(maze.cells[a], dir.bit)
	maze.cells[b] = bit32.bor(maze.cells[b], dir.opposite)
end

-- Cells reachable in one step through an open side.
function Maze.neighbors(maze: Maze, x: number, y: number): { { x: number, y: number } }
	local out = {}
	for _, d in DIRS do
		if Maze.isOpen(maze, x, y, d.bit) then
			table.insert(out, { x = x + d.dx, y = y + d.dy })
		end
	end
	return out
end

-- Depth-first carve gives a perfect maze (one route between any two cells); then a fraction of the
-- remaining interior walls are knocked out so there are loops to run around.
-- `rng` must offer :int(min, max) and :shuffle(list).
function Maze.generate(width: number, height: number, rng: any, loopFraction: number): Maze
	assert(width >= 2 and height >= 2, "maze must be at least 2x2")
	local maze: Maze = { width = width, height = height, cells = {} }
	for i = 1, width * height do
		maze.cells[i] = 0
	end

	local visited: { [number]: boolean } = { [index(maze, 1, 1)] = true }
	local stack = { { x = 1, y = 1 } }
	while #stack > 0 do
		local cur = stack[#stack]
		local options: { Dir } = {}
		for _, d in DIRS do
			local nx, ny = cur.x + d.dx, cur.y + d.dy
			if Maze.inBounds(maze, nx, ny) and not visited[index(maze, nx, ny)] then
				table.insert(options, d)
			end
		end
		if #options == 0 then
			table.remove(stack)
		else
			local d = options[rng:int(1, #options)]
			carve(maze, cur.x, cur.y, d)
			visited[index(maze, cur.x + d.dx, cur.y + d.dy)] = true
			table.insert(stack, { x = cur.x + d.dx, y = cur.y + d.dy })
		end
	end

	-- Closed interior walls: only look east and south so each wall is listed once.
	local walls: { { x: number, y: number, dir: Dir } } = {}
	for y = 1, height do
		for x = 1, width do
			for _, d in DIRS do
				if (d.bit == Maze.E or d.bit == Maze.S) and Maze.inBounds(maze, x + d.dx, y + d.dy) and not Maze.isOpen(maze, x, y, d.bit) then
					table.insert(walls, { x = x, y = y, dir = d })
				end
			end
		end
	end
	rng:shuffle(walls)
	local toRemove = math.floor(#walls * math.clamp(loopFraction, 0, 1))
	for i = 1, toRemove do
		local w = walls[i]
		carve(maze, w.x, w.y, w.dir)
	end
	return maze
end

-- Number of independent loops: open passages minus the passages a loop-free maze would have.
function Maze.cycleCount(maze: Maze): number
	local passages = 0
	for y = 1, maze.height do
		for x = 1, maze.width do
			if Maze.isOpen(maze, x, y, Maze.E) then
				passages += 1
			end
			if Maze.isOpen(maze, x, y, Maze.S) then
				passages += 1
			end
		end
	end
	return passages - (maze.width * maze.height - 1)
end

function Maze.deadEnds(maze: Maze): { { x: number, y: number } }
	local out = {}
	for y = 1, maze.height do
		for x = 1, maze.width do
			if #Maze.neighbors(maze, x, y) == 1 then
				table.insert(out, { x = x, y = y })
			end
		end
	end
	return out
end

-- Breadth-first shortest route between two cells, as a list of cells including both ends. nil if unreachable.
function Maze.findPath(maze: Maze, fromX: number, fromY: number, toX: number, toY: number): { { x: number, y: number } }?
	if not Maze.inBounds(maze, fromX, fromY) or not Maze.inBounds(maze, toX, toY) then
		return nil
	end
	local startKey, goalKey = index(maze, fromX, fromY), index(maze, toX, toY)
	local cameFrom: { [number]: number } = { [startKey] = 0 }
	local queue = { startKey }
	local head = 1
	while head <= #queue do
		local key = queue[head]
		head += 1
		if key == goalKey then
			break
		end
		local cx = (key - 1) % maze.width + 1
		local cy = (key - 1) // maze.width + 1
		for _, n in Maze.neighbors(maze, cx, cy) do
			local nk = index(maze, n.x, n.y)
			if cameFrom[nk] == nil then
				cameFrom[nk] = key
				table.insert(queue, nk)
			end
		end
	end
	if cameFrom[goalKey] == nil then
		return nil
	end
	local path = {}
	local key = goalKey
	while key ~= 0 do
		table.insert(path, 1, { x = (key - 1) % maze.width + 1, y = (key - 1) // maze.width + 1 })
		key = cameFrom[key]
	end
	return path
end

function Maze.cellToWorld(x: number, y: number, cellSize: number): (number, number)
	return (x - 0.5) * cellSize, (y - 0.5) * cellSize
end

function Maze.worldToCell(wx: number, wz: number, cellSize: number): (number, number)
	return math.floor(wx / cellSize) + 1, math.floor(wz / cellSize) + 1
end

return Maze
