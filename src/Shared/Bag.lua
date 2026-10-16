--!strict
-- The bag a player carries into an area. Parts in it are only theirs once they escape (spec section 4).

local Bag = {}
Bag.__index = Bag

export type Part = { id: string, species: string, slot: string, rarity: string }

export type Bag = typeof(setmetatable({} :: { capacity: number, items: { Part } }, Bag))

function Bag.new(capacity: number): Bag
	assert(capacity >= 1, "bag capacity must be at least 1")
	return setmetatable({ capacity = capacity, items = {} }, Bag)
end

function Bag.count(self: Bag): number
	return #self.items
end

function Bag.isFull(self: Bag): boolean
	return #self.items >= self.capacity
end

function Bag.has(self: Bag, partId: string): boolean
	for _, p in self.items do
		if p.id == partId then
			return true
		end
	end
	return false
end

-- Returns true if added; false plus a reason if the bag is full or already holds that exact part.
function Bag.add(self: Bag, part: Part): (boolean, string?)
	if Bag.has(self, part.id) then
		return false, "duplicate"
	end
	if Bag.isFull(self) then
		return false, "full"
	end
	table.insert(self.items, part)
	return true, nil
end

-- A copy, so callers cannot change the bag by accident.
function Bag.contents(self: Bag): { Part }
	return table.clone(self.items)
end

-- Empties the bag and hands back what was in it. Used both when caught (parts are lost) and on escape (parts are banked).
function Bag.empty(self: Bag): { Part }
	local out = self.items
	self.items = {}
	return out
end

function Bag.setCapacity(self: Bag, capacity: number)
	assert(capacity >= #self.items, "cannot shrink the bag below what it holds")
	self.capacity = capacity
end

return Bag
