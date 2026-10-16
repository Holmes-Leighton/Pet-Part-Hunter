--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Parts = require("../src/Shared/Parts")
local Crafting = require("../src/Shared/Crafting")
local Economy = require("../src/Shared/Economy")
local Profile = require("../src/Shared/Profile")
local Config = require("../src/Shared/Config")

local function fresh(): Profile.Data
	return Profile.load(nil, Config)
end

local function give(d: Profile.Data, id: string, n: number, seed: number?): { Crafting.Item }
	local rng = Rng.new(seed or 1)
	local out = {}
	for _ = 1, n do
		table.insert(out, Crafting.addPart(Config, d, Parts.get(id) :: Parts.Def, rng, 1000))
	end
	return out
end

Test.case("sell prices rise with rarity, and higher merge tiers sell for more", function()
	local prev = 0
	for _, area in Config.Areas do
		local price = Config.Economy.SellPrice[area.name]
		Test.truthy(price > prev, area.name)
		prev = price
	end
	local common: Crafting.Item = { uid = 1, id = "Chicken_Head", tier = 1, stats = { speed = 0, bag = 0, coin = 0, luck = 0 } }
	local polished: Crafting.Item = { uid = 2, id = "Chicken_Head", tier = 2, stats = common.stats }
	local brilliant: Crafting.Item = { uid = 3, id = "Chicken_Head", tier = 3, stats = common.stats }
	Test.eq(Economy.sellValue(Config, common), 5)
	Test.truthy(Economy.sellValue(Config, polished) > Economy.sellValue(Config, common))
	Test.truthy(Economy.sellValue(Config, brilliant) > Economy.sellValue(Config, polished))
	local mythic: Crafting.Item = { uid = 4, id = "Kraken_Head", tier = 1, stats = common.stats }
	Test.eq(Economy.sellValue(Config, mythic), 2000)
end)

Test.case("selling removes the parts and pays coins; the Part Index keeps the entries", function()
	local d = fresh()
	local items = give(d, "Chicken_Head", 3)
	local ok, gained = Economy.sell(Config, d, { items[1].uid, items[2].uid })
	Test.eq(ok, true)
	Test.eq(gained, 10)
	Test.eq(d.coins, 10)
	Test.eq(#d.parts, 1)
	Test.eq(d.stats.coinsEarned, 10)
	Test.truthy(d.index.Chicken_Head ~= nil, "selling does not clear the Index")
end)

Test.case("selling is all or nothing: bad, repeated or stale uids change nothing", function()
	local d = fresh()
	local items = give(d, "Chicken_Head", 2)
	local function fails(uids: any)
		local before = #d.parts
		local ok = Economy.sell(Config, d, uids)
		Test.eq(ok, false)
		Test.eq(#d.parts, before)
		Test.eq(d.coins, 0)
	end
	fails({ items[1].uid, 9999 })
	fails({ items[1].uid, items[1].uid }) -- the same part twice must not pay twice
	fails({ "x" })
	fails({})
	fails("all")
	fails(nil)
	local many = {}
	for i = 1, Config.Economy.SellBatchLimit + 1 do
		many[i] = i
	end
	fails(many)
end)

Test.case("a part cannot be sold twice", function()
	local d = fresh()
	local it = give(d, "Chicken_Head", 1)[1]
	Test.eq((Economy.sell(Config, d, { it.uid })), true)
	Test.eq((Economy.sell(Config, d, { it.uid })), false)
	Test.eq(d.coins, 5)
end)

Test.case("coin bonuses: the 2x pass and equipped pets' coin stat multiply what selling pays", function()
	local d = fresh()
	Test.near(Economy.coinMultiplier(Config, d), 1)
	d.passes.DoubleCoins = true
	Test.near(Economy.coinMultiplier(Config, d), 2)
	-- A pet with a 50% coin bonus.
	d.coins = 1000
	local body = give(d, "Frog_Body", 1)[1]
	body.stats.coin = 50
	local pet = Crafting.buildPet(Config, d, { Body = body.uid }) :: Crafting.Pet
	Crafting.equip(d, pet.uid)
	Test.near(Economy.coinMultiplier(Config, d), 2 * 1.5, 1e-9)
	local items = give(d, "Chicken_Head", 10)
	local uids = {}
	for _, it in items do
		table.insert(uids, it.uid)
	end
	local before = d.coins
	local ok, gained = Economy.sell(Config, d, uids)
	Test.eq(ok, true)
	Test.eq(gained, 150, "10 x 5 coins x 3")
	Test.eq(d.coins, before + 150)
end)

Test.case("sell duplicates keeps the strongest copies", function()
	local d = fresh()
	local items = give(d, "Tiger_Legs", 4, 7)
	items[1].stats.speed, items[2].stats.speed, items[3].stats.speed, items[4].stats.speed = 1, 3, 2, 2.5
	Test.eq({ Economy.sellDuplicates(Config, d, "Tiger_Legs", 1, 2) }, { true, 10 })
	local left = {}
	for _, it in d.parts do
		table.insert(left, it.stats.speed)
	end
	table.sort(left)
	Test.eq(left, { 2.5, 3 }, "kept the best two")
	Test.eq({ Economy.sellDuplicates(Config, d, "Tiger_Legs", 1, 2) }, { false, "no spare copies to sell" })
	Test.eq({ Economy.sellDuplicates(Config, d, "Tiger_Legs", 1, -1) }, { false, "invalid request" })
	Test.eq({ Economy.sellDuplicates(Config, d, 5, 1, 0) }, { false, "invalid request" })
	Test.eq({ Economy.sellDuplicates(Config, d, "Tiger_Legs", 2, 0) }, { false, "no spare copies to sell" })
end)

Test.case("sell all spares keeps the best copy of every part and tier, and is one batch", function()
	local d = fresh()
	give(d, "Chicken_Head", 3, 1)
	give(d, "Tiger_Legs", 2, 2)
	give(d, "Fox_Tail", 1, 3)
	Test.eq(#d.parts, 6)
	local ok, gained = Economy.sellAllSpares(Config, d, 1)
	Test.eq(ok, true)
	Test.eq(gained, 3 * 5, "2 + 1 spares at 5 coins")
	Test.eq(#d.parts, 3, "one of each kept")
	Test.eq({ Economy.sellAllSpares(Config, d, 1) }, { false, "no spare copies to sell" })
	Test.eq({ Economy.sellAllSpares(Config, d, -1) }, { false, "invalid request" })
	-- Over the batch limit: sells up to the limit, and a second press sells the rest.
	local big = fresh()
	local per = Config.Economy.SellBatchLimit + 50
	give(big, "Chicken_Head", per, 4)
	local first = Economy.sellAllSpares(Config, big, 1)
	Test.eq(first, true)
	Test.eq(#big.parts, per - Config.Economy.SellBatchLimit)
	Test.eq((Economy.sellAllSpares(Config, big, 1)), true)
	Test.eq(#big.parts, 1)
end)

Test.case("bag upgrades: +1 slot each, costs climb steeply, capped; coins are spent", function()
	local d = fresh()
	d.coins = 1e9
	local costs = {}
	for n = 0, Config.Economy.BagUpgrade.max - 1 do
		table.insert(costs, Economy.bagUpgradeCost(Config, n))
	end
	Test.eq(costs, { 150, 375, 937, 2343, 5859 })
	Test.eq(Economy.bagUpgradeCost(Config, Config.Economy.BagUpgrade.max), nil)
	Test.eq(Economy.bagCapacity(Config, d), 3)
	for n = 1, 5 do
		Test.eq({ Economy.buyBagUpgrade(Config, d) }, { true, "ok" })
		Test.eq(Economy.bagCapacity(Config, d), 3 + n)
	end
	Test.eq({ Economy.buyBagUpgrade(Config, d) }, { false, "your bag is fully upgraded" })
	Test.eq(d.stats.coinsSpent, 150 + 375 + 937 + 2343 + 5859)
	local poor = fresh()
	poor.coins = 149
	Test.eq({ Economy.buyBagUpgrade(Config, poor) }, { false, "not enough coins" })
	Test.eq(poor.coins, 149)
end)

Test.case("bag capacity: the free path (coin upgrades + pets) stops at the ceiling, Robux has no ceiling", function()
	local d = fresh()
	d.passes.ExtraBag1 = true
	Test.eq(Economy.bagCapacity(Config, d), 3 + 2)
	d.passes.ExtraBag2 = true
	Test.eq(Economy.bagCapacity(Config, d), 3 + 4, "pass tiers do not stack")
	d.bagUpgrades = 5
	Test.eq(Economy.bagCapacity(Config, d), 3 + 5 + 4)
	d.coins = 1000
	local body = give(d, "Frog_Body", 1)[1]
	body.stats.bag = 3
	local pet = Crafting.buildPet(Config, d, { Body = body.uid }) :: Crafting.Pet
	Crafting.equip(d, pet.uid)
	Test.eq(Economy.freeCapacity(Config, d), 3 + 5 + 3, "free path: start + upgrades + pet")
	Test.eq(Economy.bagCapacity(Config, d), 3 + 5 + 3 + 4, "the pass is added on top")
	-- Push the free path past its ceiling: it stops, the Robux part keeps growing.
	d.bagUpgrades = 50
	Test.eq(Economy.freeCapacity(Config, d), Config.Bag.MaxCapacity)
	Test.eq(Economy.bagCapacity(Config, d), Config.Bag.MaxCapacity + 4)
	d.robuxBagSlots = 100
	Test.eq(Economy.bagCapacity(Config, d), Config.Bag.MaxCapacity + 4 + 100, "Robux bag slots are unlimited")
	d.robuxBagSlots = 5000
	Test.eq(Economy.bagCapacity(Config, d), Config.Bag.MaxCapacity + 4 + 5000)
end)

Test.case("the Bag Slot product is repeatable and each one adds a slot", function()
	local d = fresh()
	Test.eq(Economy.bagCapacity(Config, d), 3)
	for n = 1, 40 do
		Test.truthy(Economy.grantProduct(Config, d, "BagSlot", 0))
		Test.eq(Economy.bagCapacity(Config, d), 3 + n)
	end
	-- Coin upgrades are refused once the free path is full, but Robux slots never are.
	local full = fresh()
	full.coins = 1e12
	full.bagUpgrades = 5
	full.robuxBagSlots = 20
	Test.eq(Economy.freeCapacity(Config, full), 8)
	Test.eq({ Economy.buyBagUpgrade(Config, full) }, { false, "your bag is fully upgraded" })
end)

Test.case("premium furniture: one product per item, granted through a purchase, never for coins", function()
	local cfg: any = table.clone(Config)
	cfg.Furniture = table.clone(Config.Furniture)
	local sofa: any = table.clone(Config.Furniture[18])
	Test.eq(sofa.id, "CandySofa")
	sofa.product = 777
	cfg.Furniture[18] = sofa
	Test.eq(Economy.furnitureProduct(cfg, 777), "CandySofa")
	Test.eq(Economy.furnitureProduct(cfg, 778), nil)
	Test.eq(Economy.furnitureProduct(Config, 0), nil, "id 0 is not set up yet")
	local d = fresh()
	Test.eq(Economy.grantFurniture(cfg, d, "CandySofa"), true)
	Test.eq(Economy.grantFurniture(cfg, d, "CandySofa"), true)
	Test.eq(d.furniture.CandySofa, 2, "repeat purchases stack")
	Test.eq(Economy.grantFurniture(cfg, d, "Chair"), false, "basic furniture is coin-only")
	Test.eq(Economy.grantFurniture(cfg, d, "Nope"), false)
end)

Test.case("every premium item has a product slot and a Robux price", function()
	local n = 0
	for _, f in Config.Furniture :: any do
		if f.premium then
			n += 1
			Test.truthy(f.product ~= nil and f.product >= 0, f.id .. " product")
			Test.truthy(f.robux ~= nil and f.robux > 0, f.id .. " robux price")
		end
	end
	Test.truthy(n >= 3)
end)

Test.case("pet slots: slots 3 and 4 for coins, 5 and 6 only with the pass", function()
	local d = fresh()
	d.coins = 1e6
	Test.eq(d.petSlots, 2)
	Test.eq(Economy.petSlotCost(Config, d), 2000)
	Test.eq({ Economy.buyPetSlot(Config, d) }, { true, "ok" })
	Test.eq({ Economy.buyPetSlot(Config, d) }, { true, "ok" })
	Test.eq(d.petSlots, 4)
	Test.eq({ Economy.buyPetSlot(Config, d) }, { false, "the last pet slots come with the Extra Pet Slots pass" })
	Test.eq(d.coins, 1e6 - 10000)
	d.passes.ExtraPetSlots = true
	Economy.applyPasses(Config, d)
	Test.eq(d.petSlots, 6)
	Test.eq({ Economy.buyPetSlot(Config, d) }, { false, "you already have every pet slot" })
	local loaded = Profile.load({ passes = { ExtraPetSlots = true }, petSlots = 2 }, Config)
	Test.eq(loaded.petSlots, 6, "the pass is applied when a profile loads")
end)

Test.case("luck biases stat rolls upward without leaving the rarity range", function()
	local def = Parts.get("Tiger_Legs") :: Parts.Def
	local function average(luck: number): number
		local rng = Rng.new(99)
		local sum = 0.0
		for _ = 1, 4000 do
			local s = Parts.roll(Config.Rarity, def, rng, luck)
			Test.truthy(s.speed >= 1 - 0.01 and s.speed <= 3 + 0.01, "inside the Common range")
			sum += s.speed
		end
		return sum / 4000
	end
	local none, some, lots = average(0), average(100), average(400)
	Test.truthy(some > none + 0.1 and lots > some, string.format("%.2f < %.2f < %.2f", none, some, lots))
end)

Test.case("luck comes from pets and an active boost; the boost expires", function()
	local d = fresh()
	local now = 10000
	Test.eq(Economy.luck(Config, d, now), 0)
	Economy.grantProduct(Config, d, "LuckBoost", now)
	Test.eq(d.luckUntil, now + 1800)
	Test.eq(Economy.luck(Config, d, now + 10), 100)
	Test.eq(Economy.luck(Config, d, now + 1801), 0, "expired")
	Economy.grantProduct(Config, d, "LuckBoost", now + 600)
	Test.eq(d.luckUntil, now + 1800 + 1800, "a second boost adds time instead of replacing it")
end)

Test.case("products: coin packs add coins (not counted as earned), insurance adds a charge", function()
	local d = fresh()
	Test.truthy(Economy.grantProduct(Config, d, "CoinPackSmall", 0))
	Test.eq(d.coins, 2000)
	Test.eq(d.stats.coinsEarned, 0)
	Test.truthy(Economy.grantProduct(Config, d, "Insurance", 0))
	Test.eq(d.insurance, 1)
	Test.eq(Economy.grantProduct(Config, d, "Nope", 0), false)
end)

Test.case("insurance: each charge is used once", function()
	local d = fresh()
	Test.eq(Economy.useInsurance(d), false)
	d.insurance = 2
	Test.eq(Economy.useInsurance(d), true)
	Test.eq(Economy.useInsurance(d), true)
	Test.eq(Economy.useInsurance(d), false)
	Test.eq(d.insurance, 0)
end)

Test.case("receipts: a repeated receipt is recognised, and only recent ones are remembered", function()
	local d = fresh()
	Test.eq(Economy.recordReceipt(Config, d, "abc"), true)
	Test.eq(Economy.recordReceipt(Config, d, "abc"), false)
	Test.eq(Economy.recordReceipt(Config, d, 5), false)
	Test.eq(Economy.recordReceipt(Config, d, ""), false)
	for i = 1, Config.Economy.MaxReceipts + 20 do
		Economy.recordReceipt(Config, d, "r" .. i)
	end
	Test.eq(#d.receipts, Config.Economy.MaxReceipts)
	Test.eq(Economy.recordReceipt(Config, d, "r" .. (Config.Economy.MaxReceipts + 20)), false, "newest still remembered")
end)

Test.case("product ids: id 0 means not set up and never matches a purchase", function()
	Test.eq(Economy.productKey(Config, 0), nil)
	local cfg: any = table.clone(Config)
	cfg.Products = { CoinPackSmall = { id = 123, coins = 5 }, Other = { id = 0 } }
	Test.eq(Economy.productKey(cfg, 123), "CoinPackSmall")
	Test.eq(Economy.productKey(cfg, 999), nil)
end)

Test.case("economy numbers survive saving and loading; hacked values are repaired", function()
	local d = fresh()
	d.bagUpgrades, d.insurance, d.luckUntil, d.robuxBagSlots = 3, 2, 5000, 9
	d.receipts = { "a", "b" }
	d.stats = { coinsEarned = 77, coinsSpent = 12 }
	Test.eq(Profile.load(d, Config), d)
	local hacked = Profile.load({ bagUpgrades = 999, insurance = -5, luckUntil = 0 / 0, receipts = { 5, "ok", string.rep("x", 100) }, stats = { coinsEarned = -1 } }, Config)
	Test.eq(hacked.bagUpgrades, Config.Economy.BagUpgrade.max)
	Test.eq(hacked.insurance, 0)
	Test.eq(hacked.luckUntil, 0)
	Test.eq(hacked.receipts, { "ok" })
	Test.eq(hacked.stats.coinsEarned, 0)
end)

Test.case("every product and pass has what the shop needs", function()
	for key, p in Config.Products :: any do
		Test.truthy(type(p.name) == "string" and p.id >= 0, key)
		Test.truthy(p.coins ~= nil or p.seconds ~= nil or p.uses ~= nil or p.bagSlots ~= nil, key .. " does something")
	end
	for key in Config.Passes :: any do
		Test.truthy((Config.PassNames :: any)[key] ~= nil, key)
	end
end)

Test.done()
