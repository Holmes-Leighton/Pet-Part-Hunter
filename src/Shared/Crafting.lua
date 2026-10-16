--!strict
-- Part inventory, merge, pet building and the Part Index (spec section 5), as pure rules over the player's data.
-- The server calls these when a run ends (addPart) and when the client asks to craft; each call either fully
-- succeeds or changes nothing, so a failed request can never lose parts (spec: "a failed call can never lose parts").

local Parts = require("./Parts")

local Crafting = {}

export type Item = { uid: number, id: string, tier: number, stats: Parts.Stats } -- stats are the base roll
export type Pet = { uid: number, slots: { [string]: Item } }
export type Data = {
	coins: number,
	parts: { Item },
	pets: { Pet },
	equippedPets: { number },
	index: { [string]: { first: number, best: number } },
	nextUid: number,
	petSlots: number,
}
export type Settings = {
	Rarity: any,
	Tiers: any,
	MergeCount: number,
	Pets: any,
}

local function newUid(data: Data): number
	local uid = data.nextUid
	data.nextUid += 1
	return uid
end

-- Records that the player now has (or has had) a part, keeping the first time and the best tier.
function Crafting.noteIndex(data: Data, id: string, tier: number, now: number)
	local e = data.index[id]
	if e == nil then
		data.index[id] = { first = now, best = tier }
	elseif tier > e.best then
		e.best = tier
	end
end

-- A part a player has just escaped with: roll its stats, add it to the inventory, fill in the Part Index.
function Crafting.addPart(cfg: Settings, data: Data, def: Parts.Def, rng: any, now: number, luck: number?): Item
	local item: Item = { uid = newUid(data), id = def.id, tier = 1, stats = Parts.roll(cfg.Rarity, def, rng, luck) }
	table.insert(data.parts, item)
	Crafting.noteIndex(data, def.id, 1, now)
	return item
end

-- Stats of an item once its quality tier is applied.
function Crafting.itemStats(cfg: Settings, item: Item): Parts.Stats
	local m = cfg.Tiers[item.tier].multiplier
	return {
		speed = item.stats.speed * m,
		bag = item.stats.bag * m,
		coin = item.stats.coin * m,
		luck = item.stats.luck * m,
	}
end

-- A pet's stats: the sum of its parts, capped per stat. Bag slots are whole numbers (floored after summing).
function Crafting.petStats(cfg: Settings, pet: Pet): Parts.Stats
	local sum: Parts.Stats = { speed = 0, bag = 0, coin = 0, luck = 0 }
	local anySum: any = sum
	for _, item in pet.slots do
		local s: any = Crafting.itemStats(cfg, item)
		for _, name in Parts.StatNames do
			anySum[name] += s[name]
		end
	end
	sum.bag = math.floor(sum.bag + 1e-9)
	for _, name in Parts.StatNames do
		anySum[name] = math.min(anySum[name], (cfg.Pets.Caps :: any)[name])
	end
	return sum
end

-- Total bonuses from the equipped pets.
function Crafting.equippedStats(cfg: Settings, data: Data): Parts.Stats
	local total: Parts.Stats = { speed = 0, bag = 0, coin = 0, luck = 0 }
	local anyTotal: any = total
	for _, uid in data.equippedPets do
		for _, pet in data.pets do
			if pet.uid == uid then
				local s: any = Crafting.petStats(cfg, pet)
				for _, name in Parts.StatNames do
					anyTotal[name] += s[name]
				end
			end
		end
	end
	return total
end

-- Merge: MergeCount copies of one part at one tier become one part of the next tier (spec). The new part's base
-- stats are the average of the ones used. Takes the oldest copies first. All or nothing.
function Crafting.merge(cfg: Settings, data: Data, id: string, tier: number, now: number): (boolean, string)
	if Parts.get(id) == nil then
		return false, "unknown part"
	end
	if tier < 1 or tier >= #cfg.Tiers or tier % 1 ~= 0 then
		return false, "that tier cannot be merged"
	end
	local picked: { Item } = {}
	for _, item in data.parts do
		if item.id == id and item.tier == tier then
			table.insert(picked, item)
		end
	end
	if #picked < cfg.MergeCount then
		return false, string.format("need %d of the same part at the same tier", cfg.MergeCount)
	end
	table.sort(picked, function(a: Item, b: Item)
		return a.uid < b.uid
	end)
	local use: { [number]: boolean } = {}
	local avg: any = { speed = 0, bag = 0, coin = 0, luck = 0 }
	for i = 1, cfg.MergeCount do
		use[picked[i].uid] = true
		for _, name in Parts.StatNames do
			avg[name] += (picked[i].stats :: any)[name] / cfg.MergeCount
		end
	end
	local kept: { Item } = {}
	for _, item in data.parts do
		if not use[item.uid] then
			table.insert(kept, item)
		end
	end
	table.insert(kept, { uid = newUid(data), id = id, tier = tier + 1, stats = avg })
	data.parts = kept
	Crafting.noteIndex(data, id, tier + 1, now)
	return true, "ok"
end

-- Build a pet from `picks` (socket name -> item uid). Slots can be left empty but at least one part is needed.
-- Charges the build fee and consumes the parts (pets cannot be taken apart again). All or nothing.
function Crafting.buildPet(cfg: Settings, data: Data, picks: { [any]: any }): (Pet?, string)
	local byUid: { [number]: Item } = {}
	for _, item in data.parts do
		byUid[item.uid] = item
	end
	local slots: { [string]: Item } = {}
	local used: { [number]: boolean } = {}
	local n = 0
	for socket, uid in picks do
		local slot = if type(socket) == "string" then Parts.SocketSlot[socket] else nil
		if slot == nil or type(uid) ~= "number" then
			return nil, "invalid pick"
		end
		local item = byUid[uid]
		if item == nil or used[uid] then
			return nil, "you do not have that part"
		end
		local def = Parts.get(item.id)
		if def == nil or def.slot ~= slot then
			return nil, "that part does not fit the " .. socket .. " socket"
		end
		used[uid] = true
		slots[socket :: string] = item
		n += 1
	end
	if n == 0 then
		return nil, "pick at least one part"
	end
	if data.coins < cfg.Pets.BuildFee then
		return nil, "not enough coins"
	end
	local kept: { Item } = {}
	for _, item in data.parts do
		if not used[item.uid] then
			table.insert(kept, item)
		end
	end
	data.parts = kept
	data.coins -= cfg.Pets.BuildFee
	local pet: Pet = { uid = newUid(data), slots = slots }
	table.insert(data.pets, pet)
	return pet, "ok"
end

local function equippedIndex(data: Data, uid: number): number?
	for i, u in data.equippedPets do
		if u == uid then
			return i
		end
	end
	return nil
end

function Crafting.equip(data: Data, petUid: number): (boolean, string)
	local owned = false
	for _, p in data.pets do
		owned = owned or p.uid == petUid
	end
	if not owned then
		return false, "you do not have that pet"
	end
	if equippedIndex(data, petUid) then
		return false, "already equipped"
	end
	if #data.equippedPets >= data.petSlots then
		return false, "no free pet slot"
	end
	table.insert(data.equippedPets, petUid)
	return true, "ok"
end

function Crafting.unequip(data: Data, petUid: number): boolean
	local i = equippedIndex(data, petUid)
	if i == nil then
		return false
	end
	table.remove(data.equippedPets, i)
	return true
end

-- What everyone else may see of a player's pets (spec: pets are a status symbol, so every client shows every
-- player's equipped pets). Only ids and tiers go out, never stats or inventory. Order is the equip order.
export type PublicPet = { uid: number, slots: { [string]: { id: string, tier: number } } }

function Crafting.publicPets(data: Data): { PublicPet }
	local out: { PublicPet } = {}
	for _, uid in data.equippedPets do
		for _, pet in data.pets do
			if pet.uid == uid then
				local slots: { [string]: { id: string, tier: number } } = {}
				for socket, item in pet.slots do
					slots[socket] = { id = item.id, tier = item.tier }
				end
				table.insert(out, { uid = pet.uid, slots = slots })
			end
		end
	end
	return out
end

-- Part Index progress: entries found out of every part in the game. Entries stay when parts are sold or used.
function Crafting.indexProgress(data: Data): (number, number)
	local found = 0
	for id in data.index do
		if Parts.get(id) then
			found += 1
		end
	end
	return found, Parts.count()
end

-- Species completion (spec: completing a species gives a small permanent bonus and a badge).
function Crafting.completedSpecies(data: Data): { string }
	local have: { [string]: number } = {}
	local need: { [string]: number } = {}
	for _, def in Parts.all() do
		need[def.species] = (need[def.species] or 0) + 1
		if data.index[def.id] then
			have[def.species] = (have[def.species] or 0) + 1
		end
	end
	local out = {}
	for sp, n in need do
		if have[sp] == n then
			table.insert(out, sp)
		end
	end
	table.sort(out)
	return out
end

return Crafting
