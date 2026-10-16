--!strict
-- Decides where things go in a generated maze (spec section 4): the entrance, the chaser's start, the teleport-out
-- points (at junctions near loops, never dead ends, spread far apart) and the part spawn cells.
-- `maze` is a Maze.Maze; the Maze module is passed in so this file needs no requires (Roblox and tests load it differently).

local AreaLayout = {}

export type Cell = { x: number, y: number }

export type Layout = {
	entrance: Cell,
	chaserStart: Cell,
	exits: { Cell },
	spawnCells: { Cell },
}

export type Options = {
	exitCount: number,
	spawnCount: number,
	minExitSeparation: number, -- in maze steps, between any two exits and from the entrance
}

local function key(maze: any, c: Cell): number
	return (c.y - 1) * maze.width + c.x
end

function AreaLayout.generate(Maze: any, maze: any, rng: any, opts: Options): Layout
	local entrance: Cell = { x = 1, y = 1 }
	local fromEntrance = Maze.distances(maze, entrance.x, entrance.y)

	-- The chaser starts as far from the entrance as the maze allows.
	local chaserStart: Cell = entrance
	local farthest = -1
	for y = 1, maze.height do
		for x = 1, maze.width do
			local d = fromEntrance[key(maze, { x = x, y = y })]
			if d > farthest then
				farthest, chaserStart = d, { x = x, y = y }
			end
		end
	end

	-- Exit candidates: junctions (3+ ways out), so a chaser can be dodged around a loop; never dead ends.
	local junctions: { Cell } = {}
	for y = 1, maze.height do
		for x = 1, maze.width do
			local c = { x = x, y = y }
			if #Maze.neighbors(maze, x, y) >= 3 and fromEntrance[key(maze, c)] >= opts.minExitSeparation then
				table.insert(junctions, c)
			end
		end
	end
	rng:shuffle(junctions)

	-- Greedy spread: take a candidate only if it is far from the entrance and every exit already chosen.
	local exits: { Cell } = {}
	local distFromExit: { { [number]: number } } = {}
	for _, c in junctions do
		if #exits >= opts.exitCount then
			break
		end
		local ok = true
		for i = 1, #exits do
			if distFromExit[i][key(maze, c)] < opts.minExitSeparation then
				ok = false
				break
			end
		end
		if ok then
			table.insert(exits, c)
			local dist: { [number]: number } = Maze.distances(maze, c.x, c.y)
			table.insert(distFromExit, dist)
		end
	end

	-- Part spawns: any other cell, shuffled; the entrance, exits and the chaser's start stay clear.
	local blocked: { [number]: boolean } = { [key(maze, entrance)] = true, [key(maze, chaserStart)] = true }
	for _, c in exits do
		blocked[key(maze, c)] = true
	end
	local pool: { Cell } = {}
	for y = 1, maze.height do
		for x = 1, maze.width do
			local c = { x = x, y = y }
			if not blocked[key(maze, c)] then
				table.insert(pool, c)
			end
		end
	end
	rng:shuffle(pool)
	local spawnCells: { Cell } = {}
	for i = 1, math.min(opts.spawnCount, #pool) do
		table.insert(spawnCells, pool[i])
	end

	return { entrance = entrance, chaserStart = chaserStart, exits = exits, spawnCells = spawnCells }
end

return AreaLayout
