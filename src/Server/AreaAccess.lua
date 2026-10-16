--!strict
-- Who may enter which area (spec section 4). The rules are in Shared/Areas; this module connects them to Roblox:
--   * on load it checks which early-access game passes the player owns (the paid route) and stores any area unlocks,
--   * it listens for game pass purchases made in-game,
--   * it tells players about new unlocks and prompts a purchase when someone tries a locked area.
-- Unlocks are permanent and live in the player's saved data (data.areas).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Areas = require(Shared:WaitForChild("Areas"))
local Config = require(Shared:WaitForChild("Config"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Analytics = require(script.Parent:WaitForChild("Analytics"))

local AreaAccess = {}

local PROMPT_COOLDOWN = 8 -- seconds between locked-area messages / purchase prompts per player and area
local lastPrompt: { [Player]: { [string]: number } } = {}
local notifyRemote: RemoteEvent? = nil

local function tell(player: Player, text: string)
	if notifyRemote then
		notifyRemote:FireClient(player, text)
	end
end

-- Mirrors unlocks to player attributes so the UI can show lock icons.
local function publish(player: Player, data: any)
	for _, def in Config.Areas do
		player:SetAttribute("Unlocked_" .. def.name, data.areas[def.name] == true)
	end
end

-- Stores newly earned unlocks and announces them. Safe to call whenever rebirths or passes may have changed.
function AreaAccess.refresh(player: Player)
	local data = PlayerData.get(player)
	if data == nil then
		return
	end
	for _, name in Areas.refreshUnlocks(Config, data) do
		Analytics.log(player, "AreaUnlocked", Areas.index(Config, name))
		tell(player, name .. " area unlocked!")
	end
	publish(player, data)
end

local function grantPass(player: Player, key: string)
	local data = PlayerData.get(player)
	if data and not data.passes[key] then
		data.passes[key] = true
		AreaAccess.refresh(player)
	end
end

-- True if the player may enter `name`. Otherwise tells them why (rate limited) and offers the pass purchase.
function AreaAccess.check(player: Player, name: string): boolean
	local data = PlayerData.get(player)
	if data == nil then
		return false
	end
	if Areas.canEnter(data, name) then
		return true
	end
	local def = Areas.get(Config, name)
	local perArea = lastPrompt[player]
	if perArea == nil then
		perArea = {}
		lastPrompt[player] = perArea
	end
	local now = os.clock()
	if def and now - (perArea[name] or -1e9) >= PROMPT_COOLDOWN then
		perArea[name] = now
		tell(player, Areas.lockedHint(def))
		local id = def.pass and Config.Passes[def.pass]
		if id and id > 0 then
			pcall(function()
				MarketplaceService:PromptGamePassPurchase(player, id)
			end)
		end
	end
	return false
end

function AreaAccess.start(notify: RemoteEvent)
	notifyRemote = notify

	PlayerData.onLoaded(function(player, data)
		-- Passes the player already owns on Roblox (ids of 0 are not set up yet).
		for key, id in Config.Passes do
			if id > 0 and not data.passes[key] then
				local ok, owns = pcall(function()
					return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
				end)
				if ok and owns then
					data.passes[key] = true
				end
			end
		end
		AreaAccess.refresh(player)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		if not purchased then
			return
		end
		for key, id in Config.Passes do
			if id > 0 and id == passId then
				Analytics.log(player, "PassPurchased", passId)
				grantPass(player, key)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastPrompt[player] = nil
	end)

	-- Studio only: player:SetAttribute("DebugGrantPass", "Area_Mythic") from the command bar to test pass unlocks.
	if RunService:IsStudio() then
		local function watch(player: Player)
			player:GetAttributeChangedSignal("DebugGrantPass"):Connect(function()
				local key = player:GetAttribute("DebugGrantPass")
				if type(key) == "string" and Config.Passes[key] ~= nil then
					grantPass(player, key)
				end
			end)
		end
		Players.PlayerAdded:Connect(watch)
		for _, p in Players:GetPlayers() do
			watch(p)
		end
	end
end

return AreaAccess
