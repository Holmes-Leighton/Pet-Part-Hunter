--!strict
-- The part data table (spec section 5): every part that can exist, plus how its stats are rolled. A part is
-- identified as <Species>_<Slot> (spec section 6 naming). Mesh and animation IDs join this table with the art
-- pipeline; until then parts are placeholders. Pure data and maths, no Roblox.

local Parts = {}

export type Def = { id: string, species: string, slot: string, rarity: string, area: string, world: number }
export type Stats = { speed: number, bag: number, coin: number, luck: number }

Parts.Slots = { "Head", "Body", "Legs", "Tail", "Special" } -- part slot types
-- Pet rig sockets (spec section 6) and which part slot each takes.
Parts.Sockets = { "Head", "Body", "Legs", "Tail", "Special1", "Special2" }
Parts.SocketSlot = ({ Head = "Head", Body = "Body", Legs = "Legs", Tail = "Tail", Special1 = "Special", Special2 = "Special" } :: any) :: { [string]: string }
Parts.StatNames = { "speed", "bag", "coin", "luck" }

-- How much of a part's rolled quality each slot turns into each stat. Body is the largest contribution, Legs are
-- mostly speed, Tail is small, Special is a small bonus so cosmetic collecting is never mandatory (spec section 5).
-- bag is in slots (tiny weights; the pet total is floored), the rest in percent.
Parts.StatWeights = ({
	Head = { luck = 1.0, coin = 0.5 },
	Body = { coin = 1.0, luck = 0.5, speed = 0.3, bag = 0.08 },
	Legs = { speed = 1.0, luck = 0.2 },
	Tail = { luck = 0.4 },
	Special = { speed = 0.2, coin = 0.2, luck = 0.2 },
} :: any) :: { [string]: { [string]: number } }

-- Species per area. Prototype species for the Common area; the other areas fill in with the content waves.
local SPECIES: { { name: string, rarity: string, area: string } } = {
	{ name = "Chicken", rarity = "Common", area = "Common" },
	{ name = "Tiger", rarity = "Common", area = "Common" },
	{ name = "Frog", rarity = "Common", area = "Common" },
	{ name = "Fox", rarity = "Common", area = "Common" },
	{ name = "Owl", rarity = "Common", area = "Common" },
}

local all: { Def } = {}
local byId: { [string]: Def } = {}
for _, sp in SPECIES do
	for _, slot in Parts.Slots do
		local def: Def = { id = sp.name .. "_" .. slot, species = sp.name, slot = slot, rarity = sp.rarity, area = sp.area, world = 1 }
		table.insert(all, def)
		byId[def.id] = def
	end
end

function Parts.all(): { Def }
	return all
end

function Parts.get(id: string): Def?
	return byId[id]
end

function Parts.count(): number
	return #all
end

-- Spawn templates for an area, in the shape PartSpawner expects. Special parts spawn at half rate (spec section 4).
function Parts.templates(area: string): { { species: string, slot: string, rarity: string, weight: number? } }
	local out = {}
	for _, def in all do
		if def.area == area then
			table.insert(out, { species = def.species, slot = def.slot, rarity = def.rarity, weight = if def.slot == "Special" then 0.5 else nil })
		end
	end
	return out
end

local function round2(v: number): number
	return math.floor(v * 100 + 0.5) / 100
end

-- Rolls a part's base stats (before the quality-tier multiplier) when it drops. rng:next() is in [0, 1).
function Parts.roll(rarityRanges: any, def: Def, rng: { next: (any) -> number }): Stats
	local range = rarityRanges[def.rarity]
	local quality = range.min + (range.max - range.min) * rng:next()
	local stats: Stats = { speed = 0, bag = 0, coin = 0, luck = 0 }
	for stat, weight in Parts.StatWeights[def.slot] do
		(stats :: any)[stat] = round2(quality * weight)
	end
	return stats
end

return Parts
