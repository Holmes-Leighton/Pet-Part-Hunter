--!strict
-- Live tuning (spec section 8): settings an admin can change while the game runs, without a restart. Each setting has a
-- type and a safe range, so a typo cannot freeze every chaser or make parts respawn every frame. Pure logic; the server's
-- TuningService stores the values, shares them between servers and applies them.
--
-- Keys:
--   chaserMult          number  x on every chaser's speed (spec: "change chaser speed")
--   respawnMult         number  x on how long a taken part takes to respawn (spawn rates)
--   tradingEnabled      bool    the trade on/off switch
--   area.<Name>.chaser  number  x on one area's chaser, on top of chaserMult
--   area.<Name>.open    bool    false closes one area for maintenance

local Tuning = {}

export type Values = { [string]: number | boolean }

local GLOBALS: { [string]: { kind: string, min: number?, max: number?, default: number | boolean } } = {
	chaserMult = { kind = "number", min = 0.2, max = 3, default = 1 },
	respawnMult = { kind = "number", min = 0.1, max = 10, default = 1 },
	tradingEnabled = { kind = "boolean", default = true },
}

-- Which setting a key is, or nil if it is not a real one. Per-area keys must name a real area.
local function spec(cfg: any, key: string): { kind: string, min: number?, max: number?, default: number | boolean }?
	local g = GLOBALS[key]
	if g then
		return g
	end
	local area, what = string.match(key, "^area%.(%w+)%.(%a+)$")
	if area == nil then
		return nil
	end
	for _, a in cfg.Areas do
		if a.name == area then
			if what == "chaser" then
				return { kind = "number", min = 0.2, max = 3, default = 1 }
			elseif what == "open" then
				return { kind = "boolean", default = true }
			end
		end
	end
	return nil
end

-- Checks and cleans a value for a key. Returns true and the clean value, or false and why.
function Tuning.check(cfg: any, key: any, value: any): (boolean, any)
	if type(key) ~= "string" then
		return false, "unknown setting"
	end
	local s = spec(cfg, key)
	if s == nil then
		return false, "unknown setting"
	end
	if s.kind == "boolean" then
		if type(value) ~= "boolean" then
			return false, key .. " is on or off"
		end
		return true, value
	end
	if type(value) ~= "number" or value ~= value or value < (s.min :: number) or value > (s.max :: number) then
		return false, string.format("%s must be between %s and %s", tostring(key), tostring(s.min), tostring(s.max))
	end
	return true, value
end

function Tuning.new(): Values
	return {}
end

-- Sets a value. Setting it back to its default removes it, so stored tuning only lists what is actually changed.
function Tuning.set(cfg: any, values: Values, key: any, value: any): (boolean, string)
	local ok, clean = Tuning.check(cfg, key, value)
	if not ok then
		return false, clean
	end
	local s = spec(cfg, key :: string) :: any
	values[key :: string] = if clean == s.default then nil else clean
	return true, "ok"
end

function Tuning.get(cfg: any, values: Values, key: string): number | boolean
	local v = values[key]
	if v ~= nil then
		return v
	end
	local s = spec(cfg, key)
	return if s then s.default else 1
end

-- Cleans a stored table: drops unknown keys and out-of-range values, so a hand-edited store cannot do damage.
function Tuning.sanitize(cfg: any, raw: any): Values
	local out: Values = {}
	if type(raw) == "table" then
		for k, v in raw do
			Tuning.set(cfg, out, k, v)
		end
	end
	return out
end

-- The chaser speed multiplier for an area: global times the area's own.
function Tuning.chaserMult(cfg: any, values: Values, area: string): number
	return (Tuning.get(cfg, values, "chaserMult") :: number) * (Tuning.get(cfg, values, "area." .. area .. ".chaser") :: number)
end

function Tuning.areaOpen(cfg: any, values: Values, area: string): boolean
	return Tuning.get(cfg, values, "area." .. area .. ".open") ~= false
end

-- Every setting an admin can change, with its current value, for the panel.
function Tuning.list(cfg: any, values: Values): { { key: string, value: number | boolean, default: number | boolean, kind: string } }
	local out = {}
	local function add(key: string)
		local s = spec(cfg, key) :: any
		table.insert(out, { key = key, value = Tuning.get(cfg, values, key), default = s.default, kind = s.kind })
	end
	for _, key in { "chaserMult", "respawnMult", "tradingEnabled" } do
		add(key)
	end
	for _, a in cfg.Areas do
		add("area." .. a.name .. ".chaser")
		add("area." .. a.name .. ".open")
	end
	return out
end

return Tuning
