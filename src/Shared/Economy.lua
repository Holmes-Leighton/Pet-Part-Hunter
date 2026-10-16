--!strict
-- Coins and what they buy (spec section 7): selling parts, bag upgrades, pet slots, bonuses from passes and pets,
-- Robux product grants and safe-to-repeat receipt handling. Pure rules over the player's data, so everything is
-- tested without Roblox; the server's EconomyService connects it to remotes and purchases.
--
-- Never sold for Robux: parts, chaser skips and escape skips (spec: the hunt stays earned). Robux items are
-- non-tradable passes, boosts and cosmetics.

local Crafting = require("./Crafting")
local House = require("./House")
local Parts = require("./Parts")

local Economy = {}

export type Data = {
	coins: number,
	passes: { [string]: boolean },
	parts: { Crafting.Item },
	pets: { Crafting.Pet },
	equippedPets: { number },
	index: { [string]: { first: number, best: number } },
	nextUid: number,
	petSlots: number,
	bagUpgrades: number,
	robuxBagSlots: number, -- repeatable Robux bag slots, no upper limit
	furniture: { [string]: number },
	insurance: number,
	luckUntil: number, -- epoch seconds the luck boost runs until (0 = none)
	receipts: { string },
	stats: { coinsEarned: number, coinsSpent: number },
}
export type Settings = any

-- Bonuses -----------------------------------------------------------------------------------------------------------
-- Multiplier on coins gained: the 2x coins pass times the equipped pets' coin bonus (a percentage).
function Economy.coinMultiplier(cfg: Settings, data: Data): number
	local mult = 1 + Crafting.equippedStats(cfg, data :: any).coin / 100
	if data.passes.DoubleCoins then
		mult *= 2
	end
	return mult
end

function Economy.luckBoostActive(data: Data, now: number): boolean
	return data.luckUntil > now
end

-- Luck percentage for rolling new parts: equipped pets plus an active luck boost.
function Economy.luck(cfg: Settings, data: Data, now: number): number
	local luck = Crafting.equippedStats(cfg, data :: any).luck
	if Economy.luckBoostActive(data, now) then
		luck += cfg.Products.LuckBoost.luck
	end
	return luck
end

-- The free path to a bigger bag: the start capacity, coin upgrades and the equipped pets' bag bonus, held under the
-- ceiling in Config.Bag.MaxCapacity.
function Economy.freeCapacity(cfg: Settings, data: Data): number
	local cap = cfg.Bag.StartCapacity + data.bagUpgrades + Crafting.equippedStats(cfg, data :: any).bag
	return math.min(cap, cfg.Bag.MaxCapacity)
end

-- Bag capacity for a new run. Paying Robux has no ceiling: the best bag pass and every Robux bag slot bought are
-- added on top of the free path, however many there are.
function Economy.bagCapacity(cfg: Settings, data: Data): number
	local pass = 0
	for key, slots in cfg.Economy.BagPass do
		if data.passes[key] then
			pass = math.max(pass, slots)
		end
	end
	return Economy.freeCapacity(cfg, data) + pass + data.robuxBagSlots
end

-- Passes that change stored numbers (call after load and after a pass is granted).
function Economy.applyPasses(cfg: Settings, data: Data)
	if data.passes.ExtraPetSlots then
		data.petSlots = math.max(data.petSlots, cfg.Pets.MaxSlots)
	end
end

local function earn(data: Data, amount: number)
	data.coins += amount
	data.stats.coinsEarned += amount
end

local function spend(data: Data, amount: number)
	data.coins -= amount
	data.stats.coinsSpent += amount
end

-- Selling ----------------------------------------------------------------------------------------------------------
-- Base coin value of a part before bonuses: priced by rarity, higher for higher merge tiers (spec).
function Economy.sellValue(cfg: Settings, item: Crafting.Item): number
	local def = Parts.get(item.id)
	if def == nil then
		return 0
	end
	local base = cfg.Economy.SellPrice[def.rarity] or 0
	local tierMult = cfg.Economy.TierPriceMultiplier[item.tier] or 1
	return base * tierMult
end

-- Sell the named parts (by uid) to the shop. All or nothing: every uid must be a part the player holds, once each.
-- Returns true and the coins gained, or false and why.
function Economy.sell(cfg: Settings, data: Data, uids: any): (boolean, any)
	if type(uids) ~= "table" or #uids == 0 or #uids > cfg.Economy.SellBatchLimit then
		return false, "nothing to sell"
	end
	local byUid: { [number]: Crafting.Item } = {}
	for _, item in data.parts do
		byUid[item.uid] = item
	end
	local chosen: { [number]: boolean } = {}
	local base = 0.0
	for _, uid in uids do
		if type(uid) ~= "number" or byUid[uid] == nil or chosen[uid] then
			return false, "some of those parts are no longer yours"
		end
		chosen[uid] = true
		base += Economy.sellValue(cfg, byUid[uid])
	end
	local kept: { Crafting.Item } = {}
	for _, item in data.parts do
		if not chosen[item.uid] then
			table.insert(kept, item)
		end
	end
	local gained = math.floor(base * Economy.coinMultiplier(cfg, data) + 1e-9)
	data.parts = kept
	earn(data, gained)
	return true, gained
end

local function statTotal(item: Crafting.Item): number
	return item.stats.speed + item.stats.bag + item.stats.coin + item.stats.luck
end

-- Sell every copy of one part at one tier except the `keep` best ones (by total stats). The "sell my duplicates"
-- button: it keeps your strongest copies for pets and merging.
function Economy.sellDuplicates(cfg: Settings, data: Data, id: any, tier: any, keep: any): (boolean, any)
	if type(id) ~= "string" or type(tier) ~= "number" or type(keep) ~= "number" or keep < 0 or keep % 1 ~= 0 then
		return false, "invalid request"
	end
	local group: { Crafting.Item } = {}
	for _, item in data.parts do
		if item.id == id and item.tier == tier then
			table.insert(group, item)
		end
	end
	table.sort(group, function(a: Crafting.Item, b: Crafting.Item)
		local sa, sb = statTotal(a), statTotal(b)
		return if sa ~= sb then sa > sb else a.uid < b.uid
	end)
	local uids = {}
	for i = keep + 1, #group do
		table.insert(uids, group[i].uid)
	end
	if #uids == 0 then
		return false, "no spare copies to sell"
	end
	return Economy.sell(cfg, data, uids)
end

-- Sell the spare copies of every part: in each group (same part, same tier) keep the `keep` best and sell the rest.
-- One batch, so it is still all or nothing; stops at the batch limit (press it again for the rest).
function Economy.sellAllSpares(cfg: Settings, data: Data, keep: any): (boolean, any)
	if type(keep) ~= "number" or keep < 0 or keep % 1 ~= 0 then
		return false, "invalid request"
	end
	local groups: { [string]: { Crafting.Item } } = {}
	for _, item in data.parts do
		local key = item.id .. "#" .. item.tier
		groups[key] = groups[key] or {}
		table.insert(groups[key], item)
	end
	local uids: { number } = {}
	for _, group in groups do
		table.sort(group, function(a: Crafting.Item, b: Crafting.Item)
			local sa, sb = statTotal(a), statTotal(b)
			return if sa ~= sb then sa > sb else a.uid < b.uid
		end)
		for i = keep + 1, #group do
			table.insert(uids, group[i].uid)
		end
	end
	table.sort(uids)
	while #uids > cfg.Economy.SellBatchLimit do
		table.remove(uids)
	end
	if #uids == 0 then
		return false, "no spare copies to sell"
	end
	return Economy.sell(cfg, data, uids)
end

-- Sinks --------------------------------------------------------------------------------------------------------------
function Economy.bagUpgradeCost(cfg: Settings, bought: number): number?
	local u = cfg.Economy.BagUpgrade
	if bought >= u.max then
		return nil
	end
	return math.floor(u.baseCost * u.growth ^ bought)
end

function Economy.buyBagUpgrade(cfg: Settings, data: Data): (boolean, string)
	local cost = Economy.bagUpgradeCost(cfg, data.bagUpgrades)
	if cost == nil then
		return false, "your bag is fully upgraded"
	end
	if Economy.freeCapacity(cfg, data) >= cfg.Bag.MaxCapacity then
		return false, "your bag is already as big as it can get"
	end
	if data.coins < cost then
		return false, "not enough coins"
	end
	spend(data, cost)
	data.bagUpgrades += 1
	return true, "ok"
end

-- The next pet slot's coin price; nil if there is none to buy with coins (slots 5 and 6 are a pass).
function Economy.petSlotCost(cfg: Settings, data: Data): number?
	return cfg.Economy.PetSlotCost[data.petSlots + 1]
end

function Economy.buyPetSlot(cfg: Settings, data: Data): (boolean, string)
	if data.petSlots >= cfg.Pets.MaxSlots then
		return false, "you already have every pet slot"
	end
	local cost = Economy.petSlotCost(cfg, data)
	if cost == nil then
		return false, "the last pet slots come with the Extra Pet Slots pass"
	end
	if data.coins < cost then
		return false, "not enough coins"
	end
	spend(data, cost)
	data.petSlots += 1
	return true, "ok"
end

-- Insurance: one use keeps the bag when caught (spec section 7).
function Economy.useInsurance(data: Data): boolean
	if data.insurance > 0 then
		data.insurance -= 1
		return true
	end
	return false
end

-- Robux products ------------------------------------------------------------------------------------------------------
function Economy.productKey(cfg: Settings, productId: number): string?
	if productId == 0 then
		return nil -- 0 means "not set up yet", never a real product
	end
	for key, p in cfg.Products do
		if p.id == productId then
			return key
		end
	end
	return nil
end

-- Remembers a purchase receipt. Returns false if it was already seen, so a repeated receipt is never granted twice.
function Economy.recordReceipt(cfg: Settings, data: Data, receiptId: any): boolean
	if type(receiptId) ~= "string" or receiptId == "" then
		return false
	end
	if table.find(data.receipts, receiptId) then
		return false
	end
	table.insert(data.receipts, receiptId)
	while #data.receipts > cfg.Economy.MaxReceipts do
		table.remove(data.receipts, 1)
	end
	return true
end

-- Grants what a developer product gives. Returns false for an unknown key. Coin packs are not "earned" coins.
function Economy.grantProduct(cfg: Settings, data: Data, key: string, now: number): boolean
	local p = cfg.Products[key]
	if p == nil then
		return false
	end
	if p.coins then
		data.coins += p.coins
	end
	if p.seconds then
		data.luckUntil = math.max(data.luckUntil, now) + p.seconds
	end
	if p.uses then
		data.insurance += p.uses
	end
	if p.bagSlots then
		data.robuxBagSlots += p.bagSlots
	end
	return true
end

-- Premium furniture is sold as one developer product per item (spec section 7). Returns the furniture id for a
-- product id, or nil. Id 0 means "not set up yet" and never matches.
function Economy.furnitureProduct(cfg: Settings, productId: number): string?
	if productId == 0 then
		return nil
	end
	for _, def in cfg.Furniture do
		if def.premium and def.product == productId then
			return def.id
		end
	end
	return nil
end

-- Grants one premium furniture item. Basic furniture is coin-only and cannot be granted through a purchase.
function Economy.grantFurniture(cfg: Settings, data: Data, id: string): boolean
	local def = House.def(cfg, id)
	if def == nil or not def.premium then
		return false
	end
	data.furniture[id] = (data.furniture[id] or 0) + 1
	return true
end

return Economy
