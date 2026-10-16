--!strict
-- The backend log for trades (spec section 9: "log every trade"). Every trade window that ends is recorded, whether it
-- completed, was cancelled, expired or failed, in three places:
--   1. a DataStore record under its own key (never edited afterwards), plus a per-player index so one player's trade
--      history is a single lookup (for support, scam reports and the admin panel);
--   2. optionally your own backend over HTTP (Config.Backend.TradeLogUrl), authenticated with a Roblox secret, with
--      retries in the background so a slow backend never holds up a trade;
--   3. the server output, with a loud warning when a record carries flags (lopsided, unusual volume).
--
-- Completed trades are logged BEFORE any items move, and if the record cannot be saved the trade does not happen
-- (outside Studio). That is what makes the log trustworthy: no swap can exist without its record.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local TradeLog = require(Shared:WaitForChild("TradeLog"))

local TradeLogger = {}

local RECENT_MAX = 100
local recent: { TradeLog.Record } = {}
local store: DataStore? = nil

local function getStore(): DataStore?
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Config.Backend.TradeStore)
		end)
		if ok then
			store = result
		end
	end
	return store
end

-- Adds the record to a player's index. Best effort: the record itself is already safe under its own key.
local function updateIndex(userId: number, rec: TradeLog.Record): boolean
	local s = getStore()
	if s == nil then
		return false
	end
	local entry = TradeLog.indexEntry(rec, userId)
	local ok = pcall(function()
		s:UpdateAsync(TradeLog.indexKey(userId), function(old: any)
			return TradeLog.addToIndex(old, entry, Config.Backend.MaxIndexPerPlayer)
		end)
	end)
	return ok
end

-- Sends a record to your own backend, retrying with a growing wait. Runs in the background.
local function postToBackend(rec: TradeLog.Record)
	local url = Config.Backend.TradeLogUrl
	if url == "" or (RunService:IsStudio() and not HttpService.HttpEnabled) then
		return
	end
	task.spawn(function()
		local body = HttpService:JSONEncode(rec)
		for attempt = 1, 5 do
			local ok, result = pcall(function()
				local headers: { [string]: any } = { ["Content-Type"] = "application/json" }
				local secretOk, secret = pcall(function()
					return (HttpService :: any):GetSecret(Config.Backend.SecretName)
				end)
				if secretOk and secret then
					headers["Authorization"] = secret:AddPrefix("Bearer ")
				end
				return HttpService:RequestAsync({ Url = url, Method = "POST", Headers = headers, Body = body })
			end)
			if ok and result.Success then
				return
			end
			task.wait(2 ^ attempt) -- 2, 4, 8, 16, 32 seconds
		end
		warn("[PetPartHunter] trade log " .. rec.id .. " could not be delivered to the backend after 5 tries")
	end)
end

-- Saves a record. Returns true when it is safely stored. Outside Studio a failure means false, and the caller must
-- not let the trade happen; in Studio (where DataStores are usually off) the record only goes to the output.
function TradeLogger.write(rec: TradeLog.Record): boolean
	table.insert(recent, rec)
	if #recent > RECENT_MAX then
		table.remove(recent, 1)
	end
	local line = TradeLog.summary(rec)
	if #rec.flags > 0 then
		warn("[PetPartHunter] " .. line)
	else
		print("[PetPartHunter] " .. line)
	end

	local saved = false
	local s = getStore()
	if s then
		for attempt = 1, Config.Backend.SaveRetries do
			local ok = pcall(function()
				s:SetAsync(TradeLog.key(rec), rec)
			end)
			if ok then
				saved = true
				break
			end
			task.wait(attempt) -- brief, growing pause between tries
		end
	end
	if saved then
		-- Indexes are best effort (and retried in the background); the record itself is already stored.
		for _, userId in { rec.a, rec.b } do
			if not updateIndex(userId, rec) then
				task.spawn(function()
					task.wait(5)
					if not updateIndex(userId, rec) then
						warn("[PetPartHunter] trade index for " .. userId .. " could not be updated for " .. rec.id)
					end
				end)
			end
		end
	end
	postToBackend(rec)
	return saved or RunService:IsStudio()
end

-- The most recent records this server has written (newest last), for the admin panel and debugging.
function TradeLogger.recent(): { TradeLog.Record }
	return recent
end

-- One player's recent trades from the index: { { id, t, s = status, w = other player, v = value given, l = lopsided } }.
function TradeLogger.history(userId: number): { TradeLog.IndexEntry }
	local s = getStore()
	if s == nil then
		return {}
	end
	local ok, list = pcall(function()
		return s:GetAsync(TradeLog.indexKey(userId))
	end)
	return if ok and type(list) == "table" then list else {}
end

-- Reads one full record by its key (TradeLog.key). The second value tells "not found" (true) apart from "could not
-- read" (false): crash recovery must not treat a failed read as "no record".
function TradeLogger.get(key: string): (TradeLog.Record?, boolean)
	local s = getStore()
	if s == nil then
		return nil, RunService:IsStudio() -- nowhere to have stored anything in Studio; in production that is a failure
	end
	local ok, rec = pcall(function()
		return s:GetAsync(key)
	end)
	if not ok then
		return nil, false
	end
	return rec, true
end

return TradeLogger
