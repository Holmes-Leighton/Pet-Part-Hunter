--!strict
-- Purchase announcements (spec section 7): when someone buys something with Robux, every player sees it in chat and
-- as a notification. The server is the only sender, so a client can never fake "X just bought Y". Only call this for
-- verified purchases (after the receipt or pass check). Rate limited per buyer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))

local Announcer = {}

local remote = Instance.new("RemoteEvent")
remote.Name = "PurchaseAnnounce"
remote.Parent = ReplicatedStorage

local limiter = RateLimiter.new(Config.Announce.PerSecond, Config.Announce.Burst)

-- `what` is our own display name for the item ("the Mythic Area Pass", "a Coin Pack"), never player-written text.
function Announcer.purchase(player: Player, what: string)
	if not Config.Announce.Enabled or not limiter:allow(player, os.clock()) then
		return
	end
	remote:FireAllClients({ userId = player.UserId, name = player.DisplayName, what = what })
end

Players.PlayerRemoving:Connect(function(player)
	limiter:forget(player)
end)

-- Studio only: player:SetAttribute("DebugPurchase", "a Test Item") from the command bar to see an announcement.
if RunService:IsStudio() then
	local function watch(player: Player)
		player:GetAttributeChangedSignal("DebugPurchase"):Connect(function()
			local what = player:GetAttribute("DebugPurchase")
			if type(what) == "string" and what ~= "" then
				Announcer.purchase(player, string.sub(what, 1, 60))
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return Announcer
