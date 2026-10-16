--!strict
-- Kicks and bans (spec section 8). Ban records live in a DataStore (Shared/Bans decides whether one still applies);
-- every player is checked as they join, and kicks and bans reach every server at once through MessagingService, so a
-- banned player cannot just hop to another server. Only AdminService calls the mutating functions, after the role check.

local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bans = require(Shared:WaitForChild("Bans"))
local Config = require(Shared:WaitForChild("Config"))

local Backend = require(script.Parent:WaitForChild("Backend"))

local BanService = {}

local TOPIC = "PPH_Admin"

local function key(userId: number): string
	return "B" .. userId
end

local function kickHere(userId: number, message: string)
	local p = Players:GetPlayerByUserId(userId)
	if p then
		p:Kick(message)
	end
end

local function broadcast(kind: string, userId: number, message: string)
	pcall(function()
		MessagingService:PublishAsync(TOPIC, { kind = kind, userId = userId, message = message })
	end)
end

-- The active ban for a user, or nil. A failed read returns nil as well: the check is retried at the next join and the
-- ban is also enforced by the cross-server kick, so a DataStore hiccup does not lock everyone out.
function BanService.get(userId: number): Bans.Ban?
	local s = Backend.store(Config.Backend.BanStore)
	if s == nil then
		return nil
	end
	local ok, rec = Backend.retry(2, function()
		return s:GetAsync(key(userId))
	end)
	if ok and Bans.isActive(rec, os.time()) then
		return rec
	end
	return nil
end

function BanService.kick(userId: number, reason: string)
	local message = "You were removed from the game. Reason: " .. reason
	kickHere(userId, message)
	broadcast("kick", userId, message)
end

-- Bans a user (online or not). seconds = 0 is permanent. Returns false if the ban could not be stored.
function BanService.ban(userId: number, seconds: number, reason: string, by: number): boolean
	local ban = Bans.new(userId, seconds, reason, by, os.time())
	local s = Backend.store(Config.Backend.BanStore)
	if s then
		local ok = Backend.retry(3, function()
			s:SetAsync(key(userId), ban)
		end)
		if not ok then
			return false
		end
	elseif not Backend.available(Config.Backend.BanStore) then
		return false
	end
	local message = Bans.message(ban, os.time())
	kickHere(userId, message)
	broadcast("ban", userId, message)
	return true
end

function BanService.unban(userId: number): boolean
	local s = Backend.store(Config.Backend.BanStore)
	if s == nil then
		return Backend.available(Config.Backend.BanStore)
	end
	return (Backend.retry(3, function()
		s:RemoveAsync(key(userId))
	end))
end

function BanService.start()
	-- Checked as a player joins, before they can do anything.
	local function check(player: Player)
		local ban = BanService.get(player.UserId)
		if ban then
			player:Kick(Bans.message(ban, os.time()))
		end
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(check, player)
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(check, p)
	end
	-- Kicks and bans issued on other servers.
	pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function(msg: any)
			local data = msg.Data
			if type(data) == "table" and (data.kind == "kick" or data.kind == "ban") and type(data.userId) == "number" then
				kickHere(data.userId, tostring(data.message))
			end
		end)
	end)
end

return BanService
