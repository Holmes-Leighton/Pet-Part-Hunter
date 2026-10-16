--!strict
-- One player's run through an area: ties the bag, their chaser, the shared part spawns and the escape points together.
-- Pure logic with injected parts, so the whole chase can be tested without Roblox. The server calls update() each
-- tick with the player's position and acts on the events it returns (teleport home, give parts, and so on).

local Run = {}
Run.__index = Run

export type Zone = { x: number, z: number, radius: number }

export type Settings = {
	catchRadius: number,
	protectionSeconds: number,
	headStartSeconds: number,
	interruptDistance: number,
	pickupRadius: number,
}

-- type is "caught" (lost holds the parts dropped) or "escaped" (parts holds the banked parts).
export type Event = { type: string, lost: { any }?, parts: { any }? }

export type Run = typeof(setmetatable(
	{} :: {
		bag: any,
		chaser: any,
		spawner: any,
		timer: any,
		zones: { Zone },
		settings: Settings,
		chaserStart: { x: number, z: number },
		protection: number,
		headStart: number,
		state: "running" | "escaped",
	},
	Run
))

function Run.new(deps: { bag: any, chaser: any, spawner: any, timer: any }, zones: { Zone }, settings: Settings, chaserStart: { x: number, z: number }): Run
	local self = setmetatable({
		bag = deps.bag,
		chaser = deps.chaser,
		spawner = deps.spawner,
		timer = deps.timer,
		zones = zones,
		settings = settings,
		chaserStart = chaserStart,
		protection = settings.protectionSeconds,
		headStart = settings.headStartSeconds,
		state = "running",
	}, Run)
	self.chaser:teleport(chaserStart.x, chaserStart.z)
	return self
end

local function dist(ax: number, az: number, bx: number, bz: number): number
	return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

function Run.isProtected(self: Run): boolean
	return self.protection > 0
end

function Run.inEscapeZone(self: Run, px: number, pz: number): boolean
	for _, z in self.zones do
		if dist(px, pz, z.x, z.z) <= z.radius then
			return true
		end
	end
	return false
end

-- Try to take a part from the shared spawns. The part is only claimed if it will fit, so a full bag never wastes one.
function Run.tryPickup(self: Run, spawnId: number, px: number, pz: number): (boolean, string?)
	if self.state ~= "running" then
		return false, "not-running"
	end
	local point = self.spawner:pointOf(spawnId)
	if point == nil then
		return false, "gone"
	end
	if dist(px, pz, point.x, point.z) > self.settings.pickupRadius then
		return false, "too-far"
	end
	if self.bag:isFull() then
		return false, "full"
	end
	local spawn = self.spawner:claim(spawnId)
	if spawn == nil then
		return false, "gone"
	end
	self.bag:add(spawn.part)
	return true, nil
end

-- Advance one tick. Returns the events that happened (caught / escaped).
function Run.update(self: Run, dt: number, px: number, pz: number): { Event }
	local events: { Event } = {}
	if self.state ~= "running" then
		return events
	end

	self.protection = math.max(0, self.protection - dt)
	if self.headStart > 0 then
		self.headStart = math.max(0, self.headStart - dt)
	elseif self.protection <= 0 then
		self.chaser:step(dt, px, pz)
	end

	-- Caught: parts in the bag are lost, back to the start, and the route is rebuilt from scratch (spec section 4).
	if self.protection <= 0 and self.headStart <= 0 and self.chaser:distanceTo(px, pz) <= self.settings.catchRadius then
		table.insert(events, { type = "caught", lost = self.bag:empty() })
		self.timer:reset()
		self.protection = self.settings.protectionSeconds
		self.headStart = self.settings.headStartSeconds
		self.chaser:teleport(self.chaserStart.x, self.chaserStart.z)
		return events
	end

	local inside = Run.inEscapeZone(self, px, pz)
	local interrupted = self.chaser:distanceTo(px, pz) <= self.settings.interruptDistance and self.headStart <= 0
	self.timer:update(dt, inside, interrupted)
	if self.timer:isDone() then
		self.state = "escaped"
		table.insert(events, { type = "escaped", parts = self.bag:empty() })
	end
	return events
end

return Run
