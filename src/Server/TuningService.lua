--!strict
-- Live tuning (spec section 8): chaser speed, part respawn rate, the trade switch and per-area settings, changed from the
-- admin panel without a restart. Shared/Tuning decides what is a valid setting and value; this module keeps the current
-- values, stores them so they survive restarts, shares changes with the other servers through MessagingService, and
-- tells the rest of the server when something changed.

local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Tuning = require(Shared:WaitForChild("Tuning"))

local Backend = require(script.Parent:WaitForChild("Backend"))

local TuningService = {}

local TOPIC = "PPH_Tuning"
local KEY = "t"

local values: Tuning.Values = Tuning.new()
local rev = 0
local listeners: { () -> () } = {}

local function applyToConfig()
	-- The trade switch is read straight from Config by the trade rules, so it is applied there.
	Config.Trade.Enabled = Tuning.get(Config, values, "tradingEnabled") ~= false
end

local function changed()
	applyToConfig()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

local function fetch(): boolean
	local s = Backend.store(Config.Backend.TuningStore)
	if s == nil then
		return Backend.available(Config.Backend.TuningStore)
	end
	local ok, value = pcall(function()
		return s:GetAsync(KEY)
	end)
	if not ok then
		return false
	end
	if type(value) == "table" and value.rev ~= rev then
		values = Tuning.sanitize(Config, value.values)
		rev = value.rev or 0
		changed()
	end
	return true
end

function TuningService.values(): Tuning.Values
	return values
end

function TuningService.chaserMult(area: string): number
	return Tuning.chaserMult(Config, values, area)
end

function TuningService.respawnMult(): number
	return Tuning.get(Config, values, "respawnMult") :: number
end

function TuningService.areaOpen(area: string): boolean
	return Tuning.areaOpen(Config, values, area)
end

function TuningService.list()
	return Tuning.list(Config, values)
end

-- Called whenever any setting changes, here or on another server.
function TuningService.onChanged(fn: () -> ())
	table.insert(listeners, fn)
end

-- Changes one setting. Returns true, or false and why.
function TuningService.set(key: any, value: any): (boolean, string)
	local nextValues = table.clone(values)
	local ok, why = Tuning.set(Config, nextValues, key, value)
	if not ok then
		return false, why
	end
	return TuningService.replace(nextValues)
end

-- Resets everything to the defaults.
function TuningService.reset(): (boolean, string)
	return TuningService.replace(Tuning.new())
end

function TuningService.replace(nextValues: Tuning.Values): (boolean, string)
	local s = Backend.store(Config.Backend.TuningStore)
	if s then
		local ok = Backend.retry(3, function()
			s:UpdateAsync(KEY, function(old: any)
				return { rev = (if type(old) == "table" and type(old.rev) == "number" then old.rev else 0) + 1, values = nextValues }
			end)
		end)
		if not ok then
			return false, "could not save the setting, try again"
		end
		fetch()
		pcall(function()
			MessagingService:PublishAsync(TOPIC, { rev = rev })
		end)
	elseif Backend.available(Config.Backend.TuningStore) then
		values = nextValues -- Studio without DataStores: in memory only
		rev += 1
		changed()
	else
		return false, "tuning storage is unavailable"
	end
	return true, "ok"
end

function TuningService.start()
	task.spawn(function()
		while not fetch() do
			task.wait(10)
		end
		applyToConfig()
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function()
				task.spawn(fetch)
			end)
		end)
		while true do
			task.wait(60)
			fetch()
		end
	end)
end

return TuningService
