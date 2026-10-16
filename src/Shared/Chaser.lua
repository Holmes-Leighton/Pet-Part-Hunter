--!strict
-- The mythic creature that hunts one player through a maze (spec section 4). Pure maths: the server feeds it
-- the target position each tick and draws the result. It follows the shortest route cell by cell, lines up with
-- the corridor centre before turning, and so never cuts through a wall.
--
-- It does not require the Maze module; it is given a `Grid` adapter so it stays testable on its own.

local Chaser = {}
Chaser.__index = Chaser

export type Grid = {
	cellSize: number,
	worldToCell: (x: number, z: number) -> (number, number),
	cellToWorld: (cx: number, cy: number) -> (number, number),
	findPath: (fx: number, fy: number, tx: number, ty: number) -> { { x: number, y: number } }?,
}

export type Chaser = typeof(setmetatable(
	{} :: { grid: Grid, x: number, z: number, speed: number, routeKey: number?, routeNext: { x: number, y: number }? },
	Chaser
))

local EPS = 1e-6

function Chaser.new(grid: Grid, x: number, z: number, speed: number): Chaser
	return setmetatable({ grid = grid, x = x, z = z, speed = speed }, Chaser)
end

function Chaser.position(self: Chaser): (number, number)
	return self.x, self.z
end

function Chaser.teleport(self: Chaser, x: number, z: number)
	self.x, self.z = x, z
end

function Chaser.setSpeed(self: Chaser, speed: number)
	self.speed = speed
end

function Chaser.distanceTo(self: Chaser, x: number, z: number): number
	return math.sqrt((self.x - x) ^ 2 + (self.z - z) ^ 2)
end

-- Move toward (tx, tz) by at most `budget` along one axis; returns the distance actually used.
local function moveAxis(self: Chaser, axis: "x" | "z", target: number, budget: number): number
	local current = if axis == "x" then self.x else self.z
	local delta = target - current
	local used = math.min(math.abs(delta), budget)
	local nextValue = current + (if delta >= 0 then used else -used)
	if axis == "x" then
		self.x = nextValue
	else
		self.z = nextValue
	end
	return used
end

-- Advance by dt seconds chasing a target at (tx, tz).
function Chaser.step(self: Chaser, dt: number, tx: number, tz: number)
	local budget = self.speed * dt
	-- Each pass either spends distance or finds nothing left to do, so the loop is bounded by the route length.
	for _ = 1, 64 do
		if budget <= EPS then
			return
		end
		local cx, cy = self.grid.worldToCell(self.x, self.z)
		local gx, gy = self.grid.worldToCell(tx, tz)
		if cx == gx and cy == gy then
			-- Same cell: no walls in the way, go straight (axis by axis keeps the maths simple and exact).
			local dx, dz = tx - self.x, tz - self.z
			local dist = math.sqrt(dx * dx + dz * dz)
			if dist <= budget then
				self.x, self.z = tx, tz
			else
				self.x += dx / dist * budget
				self.z += dz / dist * budget
			end
			return
		end

		-- The route only changes when the chaser's cell or the target's cell changes, so reuse the last search.
		local routeKey = ((cy * 100 + cx) * 100 + gy) * 100 + gx
		if self.routeKey ~= routeKey then
			local path = self.grid.findPath(cx, cy, gx, gy)
			if path == nil or #path < 2 then
				return -- target is unreachable (should not happen in a connected maze)
			end
			self.routeKey = routeKey
			self.routeNext = path[2]
		end
		local nextCell = self.routeNext :: { x: number, y: number }
		local centreX, centreZ = self.grid.cellToWorld(cx, cy)
		local nextX, nextZ = self.grid.cellToWorld(nextCell.x, nextCell.y)
		local movingX = nextCell.x ~= cx

		-- First line up with the corridor centre (perpendicular to travel), then travel along it.
		local spent: number
		if movingX and math.abs(self.z - centreZ) > EPS then
			spent = moveAxis(self, "z", centreZ, budget)
		elseif (not movingX) and math.abs(self.x - centreX) > EPS then
			spent = moveAxis(self, "x", centreX, budget)
		elseif movingX then
			spent = moveAxis(self, "x", nextX, budget)
		else
			spent = moveAxis(self, "z", nextZ, budget)
		end
		budget -= spent
		if spent <= EPS then
			return
		end
	end
end

return Chaser
