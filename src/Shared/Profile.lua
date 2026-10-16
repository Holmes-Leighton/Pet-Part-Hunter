--!strict
-- A player's saved data (spec section 10): defaults, versioned loading, sanitising and the speed/rebirth/pad rules
-- that act on it. Pure tables only, so all of it is tested without Roblox; the server's PlayerData module stores it.

local Speed = require("./Speed")

local Profile = {}

export type Data = {
	version: number,
	coins: number,
	speed: number, -- running total Speed
	rebirths: number,
	padTier: number, -- highest running pad owned
	passes: { [string]: boolean },
	parts: { any }, -- part inventory (filled by the part pipeline)
	pets: { any },
	equippedPets: { any },
	house: { any },
}

export type Settings = { Speed: Speed.Settings, Pads: any, Data: any }

function Profile.default(version: number): Data
	return {
		version = version,
		coins = 0,
		speed = 0,
		rebirths = 0,
		padTier = 1,
		passes = {},
		parts = {},
		pets = {},
		equippedPets = {},
		house = {},
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

-- Loads saved data: missing or damaged fields fall back to defaults instead of erroring, and Speed is clamped to
-- what the level cap allows. Add `if raw.version < N then ... end` migration steps here when the schema changes.
function Profile.load(raw: any, cfg: Settings): Data
	local out = Profile.default(cfg.Data.SchemaVersion)
	if type(raw) ~= "table" then
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
	local anyOut: any = out
	for _, key in { "parts", "pets", "equippedPets", "house" } do
		if type(raw[key]) == "table" then
			anyOut[key] = raw[key]
		end
	end
	return out
end

function Profile.level(cfg: Speed.Settings, data: Data): number
	return Speed.levelFromTotal(cfg, data.speed)
end

function Profile.walkSpeed(cfg: Speed.Settings, data: Data): number
	return Speed.walkSpeed(cfg, Profile.level(cfg, data))
end

-- Total multiplier on Speed gained: rebirth, times the 2x pass if owned.
function Profile.gainMultiplier(cfg: Speed.Settings, data: Data): number
	local mult = Speed.rebirthMultiplier(cfg, data.rebirths)
	if data.passes.DoubleSpeed then
		mult *= cfg.PassMultiplier
	end
	return mult
end

-- Adds Speed from a base amount (pad rate x seconds), stopping at the level cap. Returns the Speed actually added.
function Profile.addSpeed(cfg: Speed.Settings, data: Data, base: number): number
	if base <= 0 then
		return 0
	end
	local before = data.speed
	data.speed = math.min(before + base * Profile.gainMultiplier(cfg, data), Speed.totalCap(cfg, data.rebirths))
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
