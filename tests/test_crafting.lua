--!strict
local Test = require("./harness")
local Rng = require("../src/Shared/Rng")
local Parts = require("../src/Shared/Parts")
local Crafting = require("../src/Shared/Crafting")
local Profile = require("../src/Shared/Profile")
local Config = require("../src/Shared/Config")

local function fresh(): Profile.Data
	return Profile.load(nil, Config)
end

local function def(id: string): Parts.Def
	return Parts.get(id) :: Parts.Def
end

local function give(d: Profile.Data, id: string, n: number, seed: number?): { Crafting.Item }
	local rng = Rng.new(seed or 1)
	local out = {}
	for _ = 1, n do
		table.insert(out, Crafting.addPart(Config, d, def(id), rng, 1000))
	end
	return out
end

Test.case("the catalog has every slot for every species, with unique spec-style ids", function()
	Test.eq(Parts.count(), 240, "48 species x 5 slots")
	Test.truthy(Parts.get("Chicken_Head") ~= nil and Parts.get("Owl_Special") ~= nil)
	Test.eq(Parts.get("Chicken_Wings"), nil)
	local seen: { [string]: boolean } = {}
	for _, p in Parts.all() do
		Test.truthy(not seen[p.id], "duplicate " .. p.id)
		seen[p.id] = true
		Test.eq(p.id, p.species .. "_" .. p.slot)
		Test.truthy((Config.Rarity :: any)[p.rarity] ~= nil, "known rarity")
	end
end)

Test.case("spawn templates cover the area's parts, Special at half weight", function()
	local t = Parts.templates({ Common = 1 })
	Test.eq(#t, 40, "8 species x 5 slots")
	local total, plain, special = 0.0, 0.0, 0.0
	for _, x in t do
		total += x.weight :: number
		if x.slot == "Special" then
			special = x.weight :: number
		else
			plain = x.weight :: number
		end
	end
	Test.near(total, 1, 1e-9, "weights add up to 1")
	Test.near(special, plain / 2, 1e-9)
	Test.eq(#Parts.templates({ Nowhere = 1 }), 0)
end)

Test.case("rolled stats stay inside the rarity range and follow the slot's roles", function()
	local rng = Rng.new(5)
	for _ = 1, 200 do
		local legs = Parts.roll(Config.Rarity, def("Tiger_Legs"), rng)
		Test.truthy(legs.speed >= 1 - 0.01 and legs.speed <= 3 + 0.01, "legs speed in Common range")
		Test.eq(legs.bag, 0)
		Test.eq(legs.coin, 0)
		local tail = Parts.roll(Config.Rarity, def("Fox_Tail"), rng)
		Test.truthy(tail.luck <= 3 * 0.4 + 0.01, "tail is small")
		local body = Parts.roll(Config.Rarity, def("Frog_Body"), rng)
		Test.truthy(body.coin >= body.luck and body.bag > 0, "body is the largest contribution")
	end
end)

Test.case("two copies of one part can roll differently", function()
	local d = fresh()
	local items = give(d, "Chicken_Head", 2)
	Test.truthy(items[1].stats.luck ~= items[2].stats.luck)
end)

Test.case("addPart gives unique uids and fills the Part Index", function()
	local d = fresh()
	local a = give(d, "Chicken_Head", 1)[1]
	local b = give(d, "Chicken_Head", 1)[1]
	Test.truthy(a.uid ~= b.uid)
	Test.eq(d.index.Chicken_Head, { first = 1000, best = 1 })
	Test.eq({ Crafting.indexProgress(d) }, { 1, Parts.count() })
end)

Test.case("merge: five of the same part and tier become one of the next tier, averaging stats", function()
	local d = fresh()
	local items = give(d, "Tiger_Legs", 6)
	Test.eq({ Crafting.merge(Config, d, "Tiger_Legs", 1, 2000) }, { true, "ok" })
	Test.eq(#d.parts, 2, "one left over plus the merged part")
	local merged: Crafting.Item? = nil
	for _, it in d.parts do
		if it.tier == 2 then
			merged = it
		end
	end
	local m = merged :: Crafting.Item
	Test.truthy(m, "merged part exists")
	local sum = 0.0
	for i = 1, 5 do
		sum += items[i].stats.speed
	end
	Test.near(m.stats.speed, sum / 5, 1e-9)
	Test.near(Crafting.itemStats(Config, m).speed, sum / 5 * 1.25, 1e-9, "tier multiplier applies")
	Test.eq(d.index.Tiger_Legs.best, 2)
	Test.eq(d.index.Tiger_Legs.first, 1000, "first-found time kept")
end)

Test.case("merge failures change nothing", function()
	local d = fresh()
	give(d, "Tiger_Legs", 4)
	local before = #d.parts
	Test.eq({ Crafting.merge(Config, d, "Tiger_Legs", 1, 1) }, { false, "need 5 of the same part at the same tier" })
	Test.eq({ Crafting.merge(Config, d, "Nope_Head", 1, 1) }, { false, "unknown part" })
	Test.eq({ Crafting.merge(Config, d, "Tiger_Legs", 3, 1) }, { false, "that tier cannot be merged" })
	Test.eq({ Crafting.merge(Config, d, "Tiger_Legs", 1.5, 1) }, { false, "that tier cannot be merged" })
	Test.eq(#d.parts, before)
end)

Test.case("tiers chain up to the top and no further", function()
	local d = fresh()
	for _ = 1, 5 do
		give(d, "Owl_Head", 5)
		Test.truthy(Crafting.merge(Config, d, "Owl_Head", 1, 1))
	end
	Test.eq(#d.parts, 5, "five tier-2 parts")
	Test.eq({ Crafting.merge(Config, d, "Owl_Head", 2, 1) }, { true, "ok" })
	Test.eq(#d.parts, 1)
	Test.eq(d.parts[1].tier, 3)
	Test.eq({ Crafting.merge(Config, d, "Owl_Head", 3, 1) }, { false, "that tier cannot be merged" })
end)

Test.case("build a pet: consumes parts and the fee, sums stats", function()
	local d = fresh()
	d.coins = 100
	local head = give(d, "Chicken_Head", 1)[1]
	local legs = give(d, "Tiger_Legs", 1)[1]
	local extra = give(d, "Frog_Body", 1)[1]
	local pet, why = Crafting.buildPet(Config, d, { Head = head.uid, Legs = legs.uid })
	Test.truthy(pet, why)
	local p = pet :: Crafting.Pet
	Test.eq(d.coins, 100 - Config.Pets.BuildFee)
	Test.eq(#d.parts, 1)
	Test.eq(d.parts[1].uid, extra.uid)
	Test.eq(#d.pets, 1)
	local st = Crafting.petStats(Config, p)
	Test.near(st.luck, head.stats.luck + legs.stats.luck, 1e-9)
	Test.near(st.speed, legs.stats.speed, 1e-9)
	Test.eq(d.index.Chicken_Head.best, 1, "the Index keeps parts used in pets")
end)

Test.case("build validation: socket fit, ownership, duplicates, empty, fee; nothing changes on failure", function()
	local d = fresh()
	d.coins = 100
	local head = give(d, "Chicken_Head", 1)[1]
	local sp1 = give(d, "Owl_Special", 1)[1]
	local sp2 = give(d, "Fox_Special", 1)[1]
	local partsBefore, coinsBefore, petsBefore = #d.parts, d.coins, #d.pets
	local function why(picks: { [any]: any }): string
		local pet, reason = Crafting.buildPet(Config, d, picks)
		Test.eq(pet, nil)
		return reason
	end
	Test.eq(why({}), "pick at least one part")
	Test.eq(why({ Body = head.uid }), "that part does not fit the Body socket")
	Test.eq(why({ Head = 9999 }), "you do not have that part")
	Test.eq(why({ Special1 = sp1.uid, Special2 = sp1.uid }), "you do not have that part")
	Test.eq(why({ Head = "x" }), "invalid pick")
	Test.eq(why({ Wings = sp1.uid }), "invalid pick")
	Test.eq(why({ [1] = head.uid }), "invalid pick")
	d.coins = 10
	Test.eq(why({ Head = head.uid }), "not enough coins")
	d.coins = coinsBefore
	Test.eq({ #d.parts, d.coins, #d.pets }, { partsBefore, coinsBefore, petsBefore }, "nothing changed")
	Test.truthy(Crafting.buildPet(Config, d, { Special1 = sp1.uid, Special2 = sp2.uid }), "two different specials fit")
end)

Test.case("pet stats are capped per stat and bag slots are whole numbers", function()
	local item: Crafting.Item = { uid = 1, id = "Frog_Body", tier = 3, stats = { speed = 500, bag = 7.9, coin = 500, luck = 500 } }
	local pet: Crafting.Pet = { uid = 2, slots = { Body = item } }
	local st = Crafting.petStats(Config, pet)
	Test.eq(st.speed, Config.Pets.Caps.speed)
	Test.eq(st.coin, Config.Pets.Caps.coin)
	Test.eq(st.bag, Config.Pets.Caps.bag)
	local small: Crafting.Pet = { uid = 3, slots = { Body = { uid = 4, id = "Frog_Body", tier = 1, stats = { speed = 0, bag = 0.9, coin = 0, luck = 0 } } } }
	Test.eq(Crafting.petStats(Config, small).bag, 0)
end)

Test.case("equip: limited slots (2 at the start), owned pets only, unequip frees a slot", function()
	local d = fresh()
	d.coins = 1000
	local pets = {}
	for i = 1, 3 do
		local part = give(d, "Chicken_Head", 1, i)[1]
		table.insert(pets, (Crafting.buildPet(Config, d, { Head = part.uid }) :: Crafting.Pet).uid)
	end
	Test.eq(d.petSlots, 2)
	Test.eq({ Crafting.equip(d, 12345) }, { false, "you do not have that pet" })
	Test.truthy(Crafting.equip(d, pets[1]))
	Test.eq({ Crafting.equip(d, pets[1]) }, { false, "already equipped" })
	Test.truthy(Crafting.equip(d, pets[2]))
	Test.eq({ Crafting.equip(d, pets[3]) }, { false, "no free pet slot" })
	Test.truthy(Crafting.unequip(d, pets[1]))
	Test.truthy(not Crafting.unequip(d, pets[1]))
	Test.truthy(Crafting.equip(d, pets[3]))
	Test.truthy(Crafting.equippedStats(Config, d).luck > 0)
end)

Test.case("pet speed bonus raises Speed gained", function()
	local plain = Profile.addSpeed(Config.Speed, fresh(), 10)
	local boosted = Profile.addSpeed(Config.Speed, fresh(), 10, 1.5)
	Test.near(boosted, plain * 1.5, 1e-9)
end)

Test.case("species completion needs all five parts in the Index", function()
	local d = fresh()
	for _, slot in Parts.Slots do
		Test.eq(#Crafting.completedSpecies(d), 0)
		give(d, "Frog_" .. slot, 1)
	end
	Test.eq(Crafting.completedSpecies(d), { "Frog" })
end)

Test.case("a saved inventory survives loading, and bad items are dropped", function()
	local d = fresh()
	d.coins = 500
	local head = give(d, "Chicken_Head", 1)[1]
	local legs = give(d, "Tiger_Legs", 1)[1]
	local pet = Crafting.buildPet(Config, d, { Head = head.uid }) :: Crafting.Pet
	Crafting.equip(d, pet.uid)
	give(d, "Owl_Body", 5)
	Crafting.merge(Config, d, "Owl_Body", 1, 5)
	local loaded = Profile.load(d, Config)
	Test.eq(loaded, d)
	Test.truthy(loaded.nextUid > legs.uid)

	local dirty: any = Profile.load(d, Config)
	table.insert(dirty.parts, { uid = 500, id = "Dragon_Head", tier = 1, stats = {} })
	table.insert(dirty.parts, { uid = legs.uid, id = "Fox_Tail", tier = 1, stats = {} }) -- duplicate uid
	table.insert(dirty.parts, { uid = 501, id = "Fox_Tail", tier = 99, stats = { speed = -5, luck = 1e9 } })
	table.insert(dirty.equippedPets, 777)
	dirty.pets[1].slots.Body = { uid = 600, id = "Chicken_Head", tier = 1, stats = {} } -- wrong socket for the part
	local cleaned = Profile.load(dirty, Config)
	local uids: { [number]: boolean } = {}
	for _, it in cleaned.parts do
		Test.truthy(it.id ~= "Dragon_Head", "unknown part dropped")
		Test.truthy(it.tier >= 1 and it.tier <= #Config.Tiers)
		Test.truthy(it.stats.speed >= 0 and it.stats.luck <= 1000)
		Test.truthy(not uids[it.uid], "unique uids")
		uids[it.uid] = true
	end
	Test.eq(cleaned.equippedPets, { pet.uid }, "unowned equipped pet dropped")
	Test.eq(cleaned.pets[1].slots.Body, nil)
	for _, it in cleaned.parts do
		Test.truthy(cleaned.nextUid > it.uid, "nextUid is past every owned uid")
	end
end)

Test.case("public pets: only equipped pets, only part ids and tiers, in equip order", function()
	local d = fresh()
	d.coins = 1000
	local made = {}
	for i = 1, 3 do
		local head = give(d, "Chicken_Head", 1, i)[1]
		local legs = give(d, "Tiger_Legs", 1, i + 10)[1]
		table.insert(made, (Crafting.buildPet(Config, d, { Head = head.uid, Legs = legs.uid }) :: Crafting.Pet).uid)
	end
	Test.eq(#Crafting.publicPets(d), 0, "nothing equipped, nothing shown")
	Crafting.equip(d, made[2])
	Crafting.equip(d, made[1])
	local pub = Crafting.publicPets(d)
	Test.eq(#pub, 2)
	Test.eq(pub[1].uid, made[2])
	Test.eq(pub[2].uid, made[1])
	Test.eq(pub[1].slots, { Head = { id = "Chicken_Head", tier = 1 }, Legs = { id = "Tiger_Legs", tier = 1 } })
	Test.eq(pub[1].slots.Head.stats, nil, "stats stay private")
end)

Test.done()
