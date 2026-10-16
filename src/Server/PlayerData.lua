--!strict
-- Loads, autosaves and releases each player's Profile data (spec section 10). One DataStore record per player holds
-- { data, lock }. The lock (server JobId + time) stops two servers writing the same profile; a lock older than
-- Config.Data.LockSeconds is treated as a crashed server and taken over. The rules for the data itself live in
-- Shared/Profile.
--
-- If the DataStore is unavailable (for example Studio without API access) the player plays on temporary data that is
-- never saved, so a failed load can never overwrite a real save.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Profile = require(Shared:WaitForChild("Profile"))
local EventStore = require(script.Parent:WaitForChild("EventStore"))
local MetricsService = require(script.Parent:WaitForChild("MetricsService"))

local PlayerData = {}

type Entry = { data: Profile.Data, persistent: boolean }

local entries: { [Player]: Entry } = {}
local store: DataStore? = nil
local closing = false
local onLoaded: { (Player, Profile.Data) -> () } = {}

local function getStore(): DataStore?
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Config.Data.StoreName)
		end)
		if ok then
			store = result
		end
	end
	return store
end

local function keyFor(player: Player): string
	return "Player_" .. player.UserId
end

-- Claims the lock and returns the saved data. Returns (true, data) on success, (true, nil) for a brand-new player,
-- (false, reason) if the profile is locked by a live server or the store failed.
local function claim(player: Player): (boolean, any)
	local s = getStore()
	if s == nil then
		return false, "datastore unavailable"
	end
	local locked = false
	local saved: any = nil
	local ok, err = pcall(function()
		s:UpdateAsync(keyFor(player), function(old: any)
			if old ~= nil and not Profile.canAcquire(old.lock, game.JobId, os.time(), Config.Data.LockSeconds) then
				locked = true
				return nil -- cancel the write, keep the other server's lock
			end
			locked = false
			saved = old and old.data
			return { data = old and old.data, lock = { jobId = game.JobId, time = os.time() } }
		end)
	end)
	if not ok then
		return false, tostring(err)
	end
	if locked then
		return false, "locked"
	end
	return true, saved
end

local function write(player: Player, entry: Entry, release: boolean): boolean
	local s = getStore()
	if s == nil or not entry.persistent then
		return false
	end
	local ok, err = pcall(function()
		s:UpdateAsync(keyFor(player), function(old: any)
			if old ~= nil and old.lock ~= nil and old.lock.jobId ~= game.JobId and os.time() - old.lock.time <= Config.Data.LockSeconds then
				return nil -- another server owns it now; never overwrite
			end
			return { data = entry.data, lock = if release then nil else { jobId = game.JobId, time = os.time() } }
		end)
	end)
	if not ok then
		warn("[PetPartHunter] save failed for " .. player.Name .. ": " .. tostring(err))
		MetricsService.record("DataStoreError", 1, { kind = "profile_save" })
	end
	return ok
end

-- The player's data, or nil until it has loaded.
function PlayerData.get(player: Player): Profile.Data?
	local e = entries[player]
	return e and e.data
end

-- Saves one player's data right now (used before confirming a Robux purchase, so a granted purchase is never lost).
-- Returns true when saved, or when there is nowhere to save (temporary data in Studio); false if the save failed.
function PlayerData.saveNow(player: Player): boolean
	local entry = entries[player]
	if entry == nil then
		return false
	end
	if not entry.persistent then
		return true
	end
	return write(player, entry, false)
end

-- Calls fn(player, data) once a player's data has loaded (immediately for players already loaded).
function PlayerData.onLoaded(fn: (Player, Profile.Data) -> ())
	table.insert(onLoaded, fn)
	for player, e in entries do
		fn(player, e.data)
	end
end

local function load(player: Player)
	-- Event parts must be registered before any profile loads, or a saved event part would be dropped and then lost on
	-- the next save. If the events cannot be read, this player plays on temporary data that is never saved.
	local eventsReady = EventStore.waitReady(20)
	local ok, result
	for attempt = 1, 3 do
		ok, result = claim(player)
		if ok or result ~= "locked" or player.Parent == nil then
			break
		end
		task.wait(3) -- the previous server may still be releasing
	end
	if player.Parent == nil then
		return
	end
	local entry: Entry
	if ok and not eventsReady then
		warn("[PetPartHunter] events not loaded; " .. player.Name .. " plays on temporary data this session")
		entry = { data = Profile.load(nil, Config), persistent = false }
	elseif ok then
		entry = { data = Profile.load(result, Config), persistent = true }
	elseif result == "locked" then
		player:Kick("Your data is in use on another server. Please rejoin in a moment.")
		return
	else
		warn("[PetPartHunter] could not load data for " .. player.Name .. " (" .. tostring(result) .. "); using temporary data")
		MetricsService.record("DataStoreError", 1, { kind = "profile_load" })
		entry = { data = Profile.load(nil, Config), persistent = false } -- includes the free areas, unlike Profile.default
	end
	entries[player] = entry
	player:SetAttribute("DataPersistent", entry.persistent)
	for _, fn in onLoaded do
		fn(player, entry.data)
	end
end

local function release(player: Player)
	local entry = entries[player]
	if entry then
		write(player, entry, true)
		entries[player] = nil
	end
end

Players.PlayerAdded:Connect(load)
for _, p in Players:GetPlayers() do
	task.spawn(load, p)
end
Players.PlayerRemoving:Connect(release)

task.spawn(function()
	while not closing do
		task.wait(Config.Data.AutosaveSeconds)
		for player, entry in entries do
			task.spawn(write, player, entry, false)
		end
	end
end)

game:BindToClose(function()
	closing = true
	local pending = 0
	for player in entries do
		pending += 1
		task.spawn(function()
			release(player)
			pending -= 1
		end)
	end
	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

return PlayerData
