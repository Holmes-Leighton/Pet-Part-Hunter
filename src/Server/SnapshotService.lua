--!strict
-- Data snapshots for rollbacks (spec section 8: "roll back to a saved data snapshot"). While a player is connected their
-- profile is copied to a separate DataStore key every few minutes, when they join and when they leave, keeping the last
-- few (Shared/Admin.pushSnapshot). An admin can then restore one after a bug or an exploit. Snapshots are the safety
-- net behind the live data, which is why they are written through the same load/clean path (Profile.load) on restore.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Admin = require(Shared:WaitForChild("Admin"))
local Config = require(Shared:WaitForChild("Config"))

local Backend = require(script.Parent:WaitForChild("Backend"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local SnapshotService = {}

local MIN_GAP = 300 -- seconds: two snapshots closer than this replace each other

local function key(userId: number): string
	return "S" .. userId
end

-- Copies the player's data into their snapshot list. Returns true if it was stored.
function SnapshotService.take(player: Player): boolean
	local data = PlayerData.get(player)
	local s = Backend.store(Config.Backend.SnapshotStore)
	if data == nil or s == nil then
		return false
	end
	-- Profile data is plain tables and numbers, so a JSON-safe copy is made by loading it through the cleaner.
	local Profile = require(Shared:WaitForChild("Profile"))
	local copy = Profile.load(data, Config)
	local snap: Admin.Snapshot = { t = os.time(), data = copy }
	return (Backend.retry(3, function()
		s:UpdateAsync(key(player.UserId), function(old: any)
			return Admin.pushSnapshot(old, snap, Config.Admin.SnapshotCount, MIN_GAP)
		end)
	end))
end

-- Lists a user's snapshots (oldest first) as { t, summary }, without sending the data itself.
function SnapshotService.list(userId: number): { { t: number, summary: any } }
	local s = Backend.store(Config.Backend.SnapshotStore)
	if s == nil then
		return {}
	end
	local ok, list = pcall(function()
		return s:GetAsync(key(userId))
	end)
	local out = {}
	if ok and type(list) == "table" then
		for _, snap in list do
			if type(snap) == "table" and type(snap.t) == "number" and type(snap.data) == "table" then
				table.insert(out, {
					t = snap.t,
					summary = { coins = snap.data.coins, parts = if type(snap.data.parts) == "table" then #snap.data.parts else 0, rebirths = snap.data.rebirths },
				})
			end
		end
	end
	return out
end

-- The raw data of snapshot number `index` (1 = oldest), or nil.
function SnapshotService.get(userId: number, index: number): any?
	local s = Backend.store(Config.Backend.SnapshotStore)
	if s == nil then
		return nil
	end
	local ok, list = pcall(function()
		return s:GetAsync(key(userId))
	end)
	if ok and type(list) == "table" and type(list[index]) == "table" then
		return list[index].data
	end
	return nil
end

function SnapshotService.start()
	PlayerData.onLoaded(function(player)
		task.spawn(SnapshotService.take, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		SnapshotService.take(player)
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Admin.SnapshotMinutes * 60)
			for _, player in Players:GetPlayers() do
				task.spawn(SnapshotService.take, player)
			end
		end
	end)
end

return SnapshotService
