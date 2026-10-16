--!strict
-- A player's saved data (spec section 10): defaults, versioned loading, sanitising and the speed/rebirth/pad rules
-- that act on it. Pure tables only, so all of it is tested without Roblox; the server's PlayerData module stores it.

local Areas = require("./Areas")
local Crafting = require("./Crafting")
local House = require("./House")
local Parts = require("./Parts")
local Speed = require("./Speed")

local Profile = {}

export type Data = {
	version: number,
	coins: number,
	speed: number, -- running total Speed
	rebirths: number,
	padTier: number, -- highest running pad owned
	passes: { [string]: boolean },
	areas: { [string]: boolean }, -- permanently unlocked areas
	parts: { Crafting.Item },
	pets: { Crafting.Pet },
	equippedPets: { number }, -- uids of equipped pets
	index: { [string]: { first: number, best: number } }, -- Part Index: first time found, best tier owned
	nextUid: number, -- next unique id for parts and pets
	petSlots: number, -- how many pets can be equipped
	furniture: { [string]: number }, -- owned furniture not placed in the house
	house: House.HouseData, -- placed layout and visitor list
}

export type Settings = { Speed: Speed.Settings, Pads: any, Data: any, Tiers: any, Pets: any, Areas: any, Passes: any, Chase: any, Maze: any, Parts: any, House: any, Furniture: any }

function Profile.default(version: number, startSlots: number?): Data
	return {
		version = version,
		coins = 0,
		speed = 0,
		rebirths = 0,
		padTier = 1,
		passes = {},
		areas = {},
		parts = {},
		pets = {},
		equippedPets = {},
		index = {},
		nextUid = 1,
		petSlots = startSlots or 2,
		furniture = {},
		house = { version = 1, items = {}, allow = {} },
	}
end

local function nonNegative(v: any, fallback: number): number
	if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
		return fallback
	end
	return v
end

local function whole(v: any, fallback: number, max: number): number
	return math.min(math.floor(nonNegative(v, fallback)), max)
end

local function cleanItem(raw: any, tierCount: number): Crafting.Item?
	if type(raw) ~= "table" or type(raw.uid) ~= "number" or type(raw.id) ~= "string" or Parts.get(raw.id) == nil then
		return nil
	end
	local stats: any = { speed = 0, bag = 0, coin = 0, luck = 0 }
	if type(raw.stats) == "table" then
		for _, name in Parts.StatNames do
			stats[name] = math.min(nonNegative(raw.stats[name], 0), 1000)
		end
	end
	return { uid = math.floor(raw.uid), id = raw.id, tier = math.clamp(whole(raw.tier, 1, tierCount), 1, tierCount), stats = stats }
end

-- Loads saved data: missing or damaged fields fall back to defaults instead of erroring, and Speed is clamped to
-- what the level cap allows. Add `if raw.version < N then ... end` migration steps here when the schema changes.
function Profile.load(raw: any, cfg: Settings): Data
	local out = Profile.default(cfg.Data.SchemaVersion, cfg.Pets.StartSlots)
	if type(raw) ~= "table" then
		Areas.refreshUnlocks(cfg, out)
		return out
	end
	out.coins = whole(raw.coins, 0, 2 ^ 53)
	out.rebirths = whole(raw.rebirths, 0, cfg.Speed.MaxRebirths)
	out.padTier = math.clamp(whole(raw.padTier, 1, #cfg.Pads), 1, #cfg.Pads)
	out.speed = math.min(nonNegative(raw.speed, 0), Speed.totalCap(cfg.Speed, out.rebirths))
	if type(raw.passes) == "table" then
		for k, v in raw.passes do
			if type(k) == "string" and v == true then
				out.passes[k] = true
			end
		end
	end
	local tierCount = #cfg.Tiers
	local maxUid = 0
	local seen: { [number]: boolean } = {}
	local function claimUid(uid: number): boolean
		if seen[uid] then
			return false
		end
		seen[uid] = true
		maxUid = math.max(maxUid, uid)
		return true
	end
	if type(raw.parts) == "table" then
		for _, r in raw.parts do
			local item = cleanItem(r, tierCount)
			if item and claimUid(item.uid) then
				table.insert(out.parts, item)
			end
		end
	end
	if type(raw.pets) == "table" then
		for _, r in raw.pets do
			if type(r) == "table" and type(r.uid) == "number" and type(r.slots) == "table" then
				local slots: { [string]: Crafting.Item } = {}
				local count = 0
				for socket, ri in r.slots do
					local item = cleanItem(ri, tierCount)
					local socketSlot = if type(socket) == "string" then Parts.SocketSlot[socket] else nil
					local def = if item then Parts.get(item.id) else nil
					if item and socketSlot and def and def.slot == socketSlot and claimUid(item.uid) then
						slots[socket] = item
						count += 1
					end
				end
				if count > 0 and claimUid(math.floor(r.uid)) then
					table.insert(out.pets, { uid = math.floor(r.uid), slots = slots })
				end
			end
		end
	end
	if type(raw.areas) == "table" then
		for _, def in cfg.Areas do
			if raw.areas[def.name] == true then
				out.areas[def.name] = true
			end
		end
	end
	Areas.refreshUnlocks(cfg, out) -- free areas, plus anything the saved rebirths or passes already earn
	out.petSlots = math.clamp(whole(raw.petSlots, cfg.Pets.StartSlots, cfg.Pets.MaxSlots), cfg.Pets.StartSlots, cfg.Pets.MaxSlots)
	if type(raw.equippedPets) == "table" then
		for _, uid in raw.equippedPets do
			local owned = false
			for _, p in out.pets do
				owned = owned or p.uid == uid
			end
			if owned and #out.equippedPets < out.petSlots and not table.find(out.equippedPets, uid) then
				table.insert(out.equippedPets, uid)
			end
		end
	end
	if type(raw.index) == "table" then
		for id, e in raw.index do
			if type(id) == "string" and Parts.get(id) and type(e) == "table" then
				out.index[id] = { first = nonNegative(e.first, 0), best = math.clamp(whole(e.best, 1, tierCount), 1, tierCount) }
			end
		end
	end
	-- Everything owned is in the Part Index (entries survive selling and merging, so this only ever adds).
	for _, item in out.parts do
		local e = out.index[item.id]
		if e == nil then
			out.index[item.id] = { first = 0, best = item.tier }
		elseif item.tier > e.best then
			e.best = item.tier
		end
	end
	if type(raw.furniture) == "table" then
		for id, n in raw.furniture do
			if type(id) == "string" and House.def(cfg, id) then
				out.furniture[id] = whole(n, 0, 9999)
			end
		end
	end
	local refunds
	out.house, refunds = House.load(cfg, raw.house, House.limit(cfg, out), claimUid)
	for id, n in refunds do
		out.furniture[id] = (out.furniture[id] or 0) + n
	end
	out.nextUid = math.max(whole(raw.nextUid, 1, 2 ^ 52), maxUid + 1)
	return out
end

function Profile.level(cfg: Speed.Settings, data: Data): number
	return Speed.levelFromTotal(cfg, data.speed)
end

function Profile.walkSpeed(cfg: Speed.Settings, data: Data): number
	return Speed.walkSpeed(cfg, Profile.level(cfg, data))
end

-- Total multiplier on Speed gained: rebirth, times the 2x pass if owned, times `extra` (equipped pets: 1 + speed%/100).
function Profile.gainMultiplier(cfg: Speed.Settings, data: Data, extra: number?): number
	local mult = Speed.rebirthMultiplier(cfg, data.rebirths) * (extra or 1)
	if data.passes.DoubleSpeed then
		mult *= cfg.PassMultiplier
	end
	return mult
end

-- Adds Speed from a base amount (pad rate x seconds), stopping at the level cap. Returns the Speed actually added.
function Profile.addSpeed(cfg: Speed.Settings, data: Data, base: number, extra: number?): number
	if base <= 0 then
		return 0
	end
	local before = data.speed
	data.speed = math.min(before + base * Profile.gainMultiplier(cfg, data, extra), Speed.totalCap(cfg, data.rebirths))
	return data.speed - before
end

-- Rebirth: resets level and Speed, keeps everything else, raises the multiplier and the level cap.
function Profile.rebirth(cfg: Speed.Settings, data: Data): boolean
	if not Speed.canRebirth(cfg, data.speed, data.rebirths) then
		return false
	end
	data.rebirths += 1
	data.speed = 0
	return true
end

-- Buys the next pad tier with coins. Tiers go in order; rebirth requirements come from Config.Pads.
function Profile.buyPad(pads: any, data: Data, tier: number): (boolean, string)
	local def = pads[tier]
	if def == nil then
		return false, "no such pad"
	end
	if tier <= data.padTier then
		return false, "already owned"
	end
	if tier ~= data.padTier + 1 then
		return false, "buy the previous pad first"
	end
	if data.rebirths < def.rebirths then
		return false, "needs rebirth " .. def.rebirths
	end
	if data.coins < def.coins then
		return false, "not enough coins"
	end
	data.coins -= def.coins
	data.padTier = tier
	return true, "ok"
end

-- Speed per second for a pad tier the player owns; nil if they do not.
function Profile.padRate(pads: any, data: Data, tier: number): number?
	local def = pads[tier]
	if def == nil or tier > data.padTier then
		return nil
	end
	return def.rate
end

-- Session lock: a record carries who holds it and when it was last refreshed. A lock held by another server is
-- respected until it is older than `ttl`, which is treated as a crashed server.
export type Lock = { jobId: string, time: number }

function Profile.canAcquire(lock: Lock?, jobId: string, now: number, ttl: number): boolean
	return lock == nil or lock.jobId == jobId or now - lock.time > ttl
end

return Profile
