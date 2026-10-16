--!strict
-- Crafting station requests (spec section 5): build a pet, merge duplicates, equip and unequip pets. The client
-- only asks; every rule lives in Shared/Crafting and is checked on the server, rate-limited, and all or nothing.
-- After every change the player gets a fresh snapshot of their inventory (InventoryState) to draw.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Crafting = require(Shared:WaitForChild("Crafting"))
local Economy = require(Shared:WaitForChild("Economy"))
local Parts = require(Shared:WaitForChild("Parts"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Analytics = require(script.Parent:WaitForChild("Analytics"))

local CraftService = {}

local state = Instance.new("RemoteEvent")
state.Name = "InventoryState"
state.Parent = ReplicatedStorage

local request = Instance.new("RemoteEvent")
request.Name = "CraftRequest"
request.Parent = ReplicatedStorage

local limiter = RateLimiter.new(Config.RateLimit.Craft.perSecond, Config.RateLimit.Craft.burst)
local inRunCheck: (Player) -> boolean = function()
	return false
end
local notifyRemote: RemoteEvent? = nil

local function itemView(item: Crafting.Item): any
	return { uid = item.uid, id = item.id, tier = item.tier, stats = Crafting.itemStats(Config, item), base = Economy.sellValue(Config, item) }
end

-- Sends the player their inventory, pets, Part Index progress and the rules the UI needs to show.
function CraftService.push(player: Player)
	local data = PlayerData.get(player)
	if data == nil then
		return
	end
	player:SetAttribute("Banked", #data.parts)
	-- Equipped pets are public: every client reads this attribute and shows the pets (see PetDisplay on the client).
	player:SetAttribute("PetsEquipped", HttpService:JSONEncode(Crafting.publicPets(data)))
	local parts = {}
	for _, item in data.parts do
		table.insert(parts, itemView(item))
	end
	local pets = {}
	for _, pet in data.pets do
		local slots = {}
		for socket, item in pet.slots do
			slots[socket] = itemView(item)
		end
		table.insert(pets, { uid = pet.uid, slots = slots, stats = Crafting.petStats(Config, pet) })
	end
	local index = {}
	for id, e in data.index do
		index[id] = e.best
	end
	local found, total = Crafting.indexProgress(data)
	state:FireClient(player, {
		coins = data.coins,
		parts = parts,
		pets = pets,
		equipped = data.equippedPets,
		petSlots = data.petSlots,
		index = index,
		indexFound = found,
		indexTotal = total,
		species = Crafting.completedSpecies(data),
		buildFee = Config.Pets.BuildFee,
		mergeCount = Config.MergeCount,
		tiers = Config.Tiers,
		totals = Crafting.equippedStats(Config, data),
		coinMult = Economy.coinMultiplier(Config, data),
		bagCapacity = Economy.bagCapacity(Config, data),
		bagCost = Economy.bagUpgradeCost(Config, data.bagUpgrades) or -1, -- -1 = fully upgraded
		bagBought = data.bagUpgrades,
		bagMax = Config.Economy.BagUpgrade.max,
		petSlotCost = Economy.petSlotCost(Config, data) or -1, -- -1 = none to buy with coins
	})
end

local function tell(player: Player, text: string)
	if notifyRemote then
		notifyRemote:FireClient(player, text)
	end
end

-- Copies a client-sent picks table, accepting only up to six socket-name -> number entries.
local function cleanPicks(raw: any): { [string]: number }?
	if type(raw) ~= "table" then
		return nil
	end
	local out: { [string]: number } = {}
	local n = 0
	for k, v in raw do
		n += 1
		if n > #Parts.Sockets or type(k) ~= "string" or type(v) ~= "number" then
			return nil
		end
		out[k] = v
	end
	return out
end

function CraftService.start(inRun: (Player) -> boolean, notify: RemoteEvent)
	inRunCheck = inRun
	notifyRemote = notify

	PlayerData.onLoaded(function(player)
		CraftService.push(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		limiter:forget(player)
	end)

	request.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any)
		local data = PlayerData.get(player)
		if data == nil or type(action) ~= "string" or not limiter:allow(player, os.clock()) then
			return
		end
		if action == "Sync" then
			CraftService.push(player)
			return
		end
		if inRunCheck(player) then
			tell(player, "Finish your run first!")
			return
		end
		if action == "Build" then
			local picks = cleanPicks(a)
			if picks == nil then
				return
			end
			local pet, why = Crafting.buildPet(Config, data, picks)
			if pet then
				Analytics.log(player, "BuildPet", pet.uid)
				tell(player, "Pet built!")
			else
				tell(player, "Cannot build: " .. why)
			end
		elseif action == "Merge" then
			if type(a) ~= "string" or type(b) ~= "number" then
				return
			end
			local ok, why = Crafting.merge(Config, data, a, b, os.time())
			Analytics.log(player, ok and "MergeOk" or "MergeFail", b)
			tell(player, if ok then "Merged into a better part!" else "Cannot merge: " .. why)
		elseif action == "Equip" then
			if type(a) ~= "number" then
				return
			end
			local ok, why = Crafting.equip(data, a)
			if not ok then
				tell(player, "Cannot equip: " .. why)
			end
		elseif action == "Unequip" then
			if type(a) ~= "number" then
				return
			end
			Crafting.unequip(data, a)
		else
			return
		end
		CraftService.push(player)
	end)
end

return CraftService
