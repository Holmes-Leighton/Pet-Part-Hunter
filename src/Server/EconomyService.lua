--!strict
-- The economy on the server (spec section 7): selling parts to the shop, buying bag upgrades and pet slots with
-- coins, and Robux developer products. The rules are in Shared/Economy (unit tested); this connects them to remotes
-- and MarketplaceService. The client only asks; every request is validated, rate limited and all or nothing.
--
-- Robux purchases use receipts the safe way: a receipt is recorded and the goods granted once, the data is saved, and
-- only then is the purchase confirmed, so a repeated or retried receipt can never grant twice or lose a purchase.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Economy = require(Shared:WaitForChild("Economy"))
local House = require(Shared:WaitForChild("House"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))

local Analytics = require(script.Parent:WaitForChild("Analytics"))
local Announcer = require(script.Parent:WaitForChild("Announcer"))
local CraftService = require(script.Parent:WaitForChild("CraftService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local EconomyService = {}

local request = Instance.new("RemoteEvent")
request.Name = "EconomyRequest"
request.Parent = ReplicatedStorage

local limiter = RateLimiter.new(Config.RateLimit.Economy.perSecond, Config.RateLimit.Economy.burst)

-- Attributes the HUD reads: remaining boosts and charges.
function EconomyService.publish(player: Player)
	local data = PlayerData.get(player)
	if data == nil then
		return
	end
	player:SetAttribute("Insurance", data.insurance)
	player:SetAttribute("LuckUntil", data.luckUntil)
	player:SetAttribute("BagCapacityStat", Economy.bagCapacity(Config, data))
	for key in Config.Passes :: any do
		player:SetAttribute("Pass_" .. key, data.passes[key] == true) -- the shop shows owned passes as OWNED
	end
end

function EconomyService.start(inRun: (Player) -> boolean, notify: RemoteEvent)
	local function tell(player: Player, text: string)
		notify:FireClient(player, text)
	end

	PlayerData.onLoaded(function(player)
		EconomyService.publish(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		limiter:forget(player)
	end)

	request.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any, c: any)
		local data = PlayerData.get(player)
		if data == nil or type(action) ~= "string" or not limiter:allow(player, os.clock()) then
			return
		end
		if inRun(player) then
			tell(player, "Finish your run first!")
			return
		end
		if action == "Sell" then
			local ok, result = Economy.sell(Config, data, a)
			if ok then
				Analytics.log(player, "CoinsEarned", result, { source = "SellParts" })
				tell(player, string.format("Sold for %d coins!", result))
			else
				tell(player, "Cannot sell: " .. tostring(result))
			end
		elseif action == "SellDuplicates" then
			local ok, result = Economy.sellDuplicates(Config, data, a, b, c)
			if ok then
				Analytics.log(player, "CoinsEarned", result, { source = "SellDuplicates" })
				tell(player, string.format("Sold duplicates for %d coins!", result))
			else
				tell(player, "Cannot sell: " .. tostring(result))
			end
		elseif action == "SellAllSpares" then
			local ok, result = Economy.sellAllSpares(Config, data, 1)
			if ok then
				Analytics.log(player, "CoinsEarned", result, { source = "SellSpares" })
				tell(player, string.format("Sold your spares for %d coins!", result))
			else
				tell(player, "Cannot sell: " .. tostring(result))
			end
		elseif action == "BuyBag" then
			local cost = Economy.bagUpgradeCost(Config, data.bagUpgrades)
			local ok, why = Economy.buyBagUpgrade(Config, data)
			if ok then
				Analytics.log(player, "CoinsSpent", cost or 0, { sink = "BagUpgrade" })
				tell(player, "Bag upgraded! Capacity is now " .. Economy.bagCapacity(Config, data))
			else
				tell(player, "Cannot upgrade: " .. why)
			end
		elseif action == "BuyPetSlot" then
			local cost = Economy.petSlotCost(Config, data)
			local ok, why = Economy.buyPetSlot(Config, data)
			if ok then
				Analytics.log(player, "CoinsSpent", cost or 0, { sink = "PetSlot" })
				tell(player, "Pet slot unlocked! You can equip " .. data.petSlots .. " pets")
			else
				tell(player, "Cannot buy: " .. why)
			end
		elseif action == "Sync" then
			-- just resend below
		else
			return
		end
		EconomyService.publish(player)
		CraftService.push(player)
	end)

	-- Robux developer products. Granted once per receipt; confirmed only after the data is saved.
	MarketplaceService.ProcessReceipt = function(info: any)
		local player = Players:GetPlayerByUserId(info.PlayerId)
		local data = if player then PlayerData.get(player) else nil
		if player == nil or data == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox retries when they are back
		end
		local key = Economy.productKey(Config, info.ProductId)
		local furnitureId = if key == nil then Economy.furnitureProduct(Config, info.ProductId) else nil
		if key == nil and furnitureId == nil then
			warn("[PetPartHunter] purchase of an unknown product " .. tostring(info.ProductId))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if Economy.recordReceipt(Config, data, tostring(info.PurchaseId)) then
			local what: string
			if key then
				Economy.grantProduct(Config, data, key, os.time())
				what = Config.Products[key].name
			else
				Economy.grantFurniture(Config, data, furnitureId :: string)
				what = "the " .. (House.def(Config, furnitureId :: string) :: any).name
			end
			Analytics.log(player, "ProductPurchased", info.ProductId, { product = key or furnitureId })
			Announcer.purchase(player, what)
			EconomyService.publish(player)
			CraftService.push(player)
		end
		-- A repeated receipt skips the grant but still waits for a successful save before confirming.
		if PlayerData.saveNow(player) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

return EconomyService
