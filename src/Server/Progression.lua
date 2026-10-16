--!strict
-- Speed pads, levels, rebirth and WalkSpeed (spec section 3), wired to players. The rules are in Shared/Profile and
-- Shared/Speed (unit tested); this module only connects them to the lobby pads, the player's character and remotes.
-- The server owns WalkSpeed: it is recomputed from saved Speed every frame and nothing the client sends changes it.
-- The client only asks for things (Rebirth, BuyPad); the server checks the rules and the rate limit.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Crafting = require(Shared:WaitForChild("Crafting"))
local Profile = require(Shared:WaitForChild("Profile"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Speed = require(Shared:WaitForChild("Speed"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Analytics = require(script.Parent:WaitForChild("Analytics"))
local AreaAccess = require(script.Parent:WaitForChild("AreaAccess"))
local EventService = require(script.Parent:WaitForChild("EventService"))

local Progression = {}

local PUBLISH_INTERVAL = 0.2 -- seconds between HUD attribute updates per player

export type Pad = { tier: number, x: number, z: number, radius: number }

-- Sets the attributes the HUD reads. Only values that changed cause a replication.
-- Equipped pets add their speed bonus (a percentage) to every Speed gain.
local function petMultiplier(data: Profile.Data): number
	return (1 + Crafting.equippedStats(Config, data).speed / 100) * EventService.mods().speed
end

local function publish(player: Player, data: Profile.Data)
	local S = Config.Speed
	local level = Profile.level(S, data)
	local into, cost = Speed.levelProgress(S, data.speed)
	local atCap = level >= Speed.levelCap(S, data.rebirths)
	player:SetAttribute("Speed", math.floor(data.speed))
	player:SetAttribute("Level", level)
	player:SetAttribute("LevelInto", math.floor(into))
	player:SetAttribute("LevelCost", math.ceil(cost))
	player:SetAttribute("LevelCap", Speed.levelCap(S, data.rebirths))
	player:SetAttribute("AtLevelCap", atCap)
	player:SetAttribute("WalkSpeedStat", Profile.walkSpeed(S, data))
	player:SetAttribute("Rebirths", data.rebirths)
	player:SetAttribute("CanRebirth", Speed.canRebirth(S, data.speed, data.rebirths))
	player:SetAttribute("NextRebirthMult", Speed.rebirthMultiplier(S, math.min(data.rebirths + 1, S.MaxRebirths)))
	player:SetAttribute("GainMult", Profile.gainMultiplier(S, data, petMultiplier(data)))
	player:SetAttribute("PadTier", data.padTier)
	player:SetAttribute("Coins", data.coins)
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		local r = stats:FindFirstChild("Rebirths") :: IntValue?
		if r then
			r.Value = data.rebirths
		end
		local l = stats:FindFirstChild("Level") :: IntValue?
		if l then
			l.Value = level
		end
	end
end

-- pads: the lobby running pads. inRun: true while a player is inside an area (pads and rebirth are lobby-only).
-- notify: the RemoteEvent used for short on-screen messages.
function Progression.start(pads: { Pad }, inRun: (Player) -> boolean, notify: RemoteEvent)
	local request = Instance.new("RemoteEvent")
	request.Name = "ProgressRequest"
	request.Parent = ReplicatedStorage

	local limiters = {
		Rebirth = RateLimiter.new(Config.RateLimit.Rebirth.perSecond, Config.RateLimit.Rebirth.burst),
		BuyPad = RateLimiter.new(Config.RateLimit.BuyPad.perSecond, Config.RateLimit.BuyPad.burst),
	}
	local lastPublish: { [Player]: number } = {}

	PlayerData.onLoaded(function(player, data)
		local stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		for _, name in { "Rebirths", "Level" } do
			local v = Instance.new("IntValue")
			v.Name = name
			v.Parent = stats
		end
		stats.Parent = player
		publish(player, data)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastPublish[player] = nil
		for _, l in limiters do
			l:forget(player)
		end
	end)

	request.OnServerEvent:Connect(function(player: Player, action: any, arg: any)
		local data = PlayerData.get(player)
		if data == nil or type(action) ~= "string" then
			return
		end
		local limiter = limiters[action :: "Rebirth" | "BuyPad"]
		if limiter == nil or not limiter:allow(player, os.clock()) then
			return
		end
		if inRun(player) then
			notify:FireClient(player, "Finish your run first!")
			return
		end
		if action == "Rebirth" then
			local before = data.rebirths
			if Profile.rebirth(Config.Speed, data) then
				Analytics.log(player, "Rebirth", data.rebirths)
				AreaAccess.refresh(player) -- the free route to the paid areas is a rebirth count
				notify:FireClient(player, string.format("REBIRTH %d! Speed gain is now x%.2f", data.rebirths, Speed.rebirthMultiplier(Config.Speed, data.rebirths)))
			else
				notify:FireClient(player, string.format("Reach level %d to rebirth (rebirths: %d)", Speed.levelCap(Config.Speed, before), before))
			end
		elseif action == "BuyPad" then
			if type(arg) ~= "number" or arg ~= arg or arg % 1 ~= 0 then
				return
			end
			local ok, why = Profile.buyPad(Config.Pads, data, arg)
			if ok then
				Analytics.log(player, "BuyPad", arg)
				notify:FireClient(player, "Unlocked running pad " .. arg)
			else
				notify:FireClient(player, "Cannot buy pad: " .. why)
			end
		end
		publish(player, data)
	end)

	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			local data = PlayerData.get(player)
			local char = player.Character
			if data == nil or char == nil then
				continue
			end

			-- Studio only: add coins from the command bar with player:SetAttribute("DebugAddCoins", n) to test pad buying.
			local debugCoins = player:GetAttribute("DebugAddCoins")
			if RunService:IsStudio() and type(debugCoins) == "number" then
				data.coins += math.max(0, math.floor(debugCoins))
				player:SetAttribute("DebugAddCoins", nil)
			end

			local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			local changed = false

			if root and not inRun(player) then
				local p = root.Position
				for _, pad in pads do
					local dx, dz = p.X - pad.x, p.Z - pad.z
					if dx * dx + dz * dz <= pad.radius * pad.radius and p.Y < 8 then
						local rate = Profile.padRate(Config.Pads, data, pad.tier)
						if rate then
							changed = Profile.addSpeed(Config.Speed, data, rate * dt, petMultiplier(data)) > 0
						end
						break
					end
				end
			end

			-- The server owns WalkSpeed.
			if humanoid then
				local walk = Profile.walkSpeed(Config.Speed, data)
				if humanoid.WalkSpeed ~= walk then
					humanoid.WalkSpeed = walk
				end
			end

			if changed or now - (lastPublish[player] or 0) >= PUBLISH_INTERVAL then
				lastPublish[player] = now
				publish(player, data)
			end
		end
	end)
end

return Progression
