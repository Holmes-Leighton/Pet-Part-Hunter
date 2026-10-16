--!strict
-- Shared part spawns for one area (spec section 4). Every player on the server sees the same parts and the
-- first claim wins. A taken part respawns at a different free spawn point after a timer.

local PartSpawner = {}
PartSpawner.__index = PartSpawner

export type Template = { species: string, slot: string, rarity: string, weight: number? }
export type Point = { x: number, z: number }
export type Spawn = { spawnId: number, pointIndex: number, part: { id: string, species: string, slot: string, rarity: string } }

export type PartSpawner = typeof(setmetatable(
	{} :: {
		rng: any,
		points: { Point },
		catalog: { Template },
		respawnSeconds: number,
		active: { [number]: Spawn }, -- by spawnId
		taken: { [number]: boolean }, -- pointIndex -> in use
		pending: { { remaining: number, avoid: number } },
		nextId: number,
	},
	PartSpawner
))

function PartSpawner.new(rng: any, points: { Point }, catalog: { Template }, count: number, respawnSeconds: number): PartSpawner
	assert(#points >= count, "need at least as many spawn points as active parts")
	assert(#catalog >= 1, "need at least one part template")
	local self: PartSpawner = setmetatable({
		rng = rng,
		points = points,
		catalog = catalog,
		respawnSeconds = respawnSeconds,
		active = {},
		taken = {},
		pending = {},
		nextId = 1,
	}, PartSpawner)
	for _ = 1, count do
		PartSpawner._spawnOne(self, 0)
	end
	return self
end

local function pickTemplate(self: PartSpawner): Template
	local total = 0
	for _, t in self.catalog do
		total += t.weight or 1
	end
	local roll = self.rng:next() * total
	for _, t in self.catalog do
		roll -= t.weight or 1
		if roll < 0 then
			return t
		end
	end
	return self.catalog[#self.catalog]
end

-- Spawn one part at a random free point, avoiding `avoid` (the point it was just taken from) when another is free.
function PartSpawner._spawnOne(self: PartSpawner, avoid: number)
	local free = {}
	for i = 1, #self.points do
		if not self.taken[i] and i ~= avoid then
			table.insert(free, i)
		end
	end
	if #free == 0 then
		for i = 1, #self.points do
			if not self.taken[i] then
				table.insert(free, i)
			end
		end
	end
	if #free == 0 then
		return
	end
	local pointIndex = free[self.rng:int(1, #free)]
	local template = pickTemplate(self)
	local spawnId = self.nextId
	self.nextId += 1
	self.taken[pointIndex] = true
	self.active[spawnId] = {
		spawnId = spawnId,
		pointIndex = pointIndex,
		part = { id = "part-" .. spawnId, species = template.species, slot = template.slot, rarity = template.rarity },
	}
end

-- Swaps the part templates future spawns draw from (events change the pool while the server runs). Parts already
-- on the ground are untouched.
function PartSpawner.setCatalog(self: PartSpawner, catalog: { Template })
	assert(#catalog >= 1, "need at least one part template")
	self.catalog = catalog
end

function PartSpawner.activeSpawns(self: PartSpawner): { Spawn }
	local out: { Spawn } = {}
	for _, s in self.active do
		table.insert(out, s)
	end
	table.sort(out, function(a: Spawn, b: Spawn)
		return a.spawnId < b.spawnId
	end)
	return out
end

function PartSpawner.pointOf(self: PartSpawner, spawnId: number): Point?
	local s = self.active[spawnId]
	return s and self.points[s.pointIndex]
end

-- First caller gets the part; later or stale claims get nil. The server decides, so a part can never be duplicated.
function PartSpawner.claim(self: PartSpawner, spawnId: number): Spawn?
	local s = self.active[spawnId]
	if s == nil then
		return nil
	end
	self.active[spawnId] = nil
	self.taken[s.pointIndex] = nil
	table.insert(self.pending, { remaining = self.respawnSeconds, avoid = s.pointIndex })
	return s
end

function PartSpawner.update(self: PartSpawner, dt: number)
	local still = {}
	for _, p in self.pending do
		p.remaining -= dt
		if p.remaining <= 0 then
			PartSpawner._spawnOne(self, p.avoid)
		else
			table.insert(still, p)
		end
	end
	self.pending = still
end

return PartSpawner
