--!strict
-- Shared test helpers.

local Maze = require("../src/Shared/Maze")

local Support = {}

function Support.gridFor(maze: Maze.Maze, cell: number)
	return {
		cellSize = cell,
		worldToCell = function(x: number, z: number): (number, number)
			local cx, cy = Maze.worldToCell(x, z, cell)
			return math.clamp(cx, 1, maze.width), math.clamp(cy, 1, maze.height)
		end,
		cellToWorld = function(cx: number, cy: number): (number, number)
			return Maze.cellToWorld(cx, cy, cell)
		end,
		findPath = function(fx: number, fy: number, tx: number, ty: number)
			return Maze.findPath(maze, fx, fy, tx, ty)
		end,
	}
end

return Support
