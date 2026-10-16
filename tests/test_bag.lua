--!strict
local Test = require("./harness")
local Bag = require("../src/Shared/Bag")
local Config = require("../src/Shared/Config")

local function part(id: string): Bag.Part
	return { id = id, species = "Chicken", slot = "Head", rarity = "Common" }
end

Test.case("a new bag starts at the spec capacity of 3", function()
	local bag = Bag.new(Config.Bag.StartCapacity)
	Test.eq(bag.capacity, 3)
	Test.eq(bag:count(), 0)
	Test.truthy(not bag:isFull())
end)

Test.case("holds up to capacity and refuses the next part", function()
	local bag = Bag.new(3)
	Test.truthy(bag:add(part("a")))
	Test.truthy(bag:add(part("b")))
	Test.truthy(bag:add(part("c")))
	Test.truthy(bag:isFull())
	local ok, reason = bag:add(part("d"))
	Test.eq(ok, false)
	Test.eq(reason, "full")
	Test.eq(bag:count(), 3)
end)

Test.case("the same part cannot go in twice", function()
	local bag = Bag.new(3)
	Test.truthy(bag:add(part("a")))
	local ok, reason = bag:add(part("a"))
	Test.eq(ok, false)
	Test.eq(reason, "duplicate")
	Test.eq(bag:count(), 1)
end)

Test.case("empty returns every part once and leaves the bag empty", function()
	local bag = Bag.new(3)
	bag:add(part("a"))
	bag:add(part("b"))
	local out = bag:empty()
	Test.eq(#out, 2)
	Test.eq(bag:count(), 0)
	Test.eq(#bag:empty(), 0)
	Test.truthy(bag:add(part("a")), "can be filled again")
end)

Test.case("contents is a copy, so editing it does not change the bag", function()
	local bag = Bag.new(3)
	bag:add(part("a"))
	local c = bag:contents()
	table.remove(c)
	Test.eq(bag:count(), 1)
end)

Test.case("upgrading capacity lets more in; shrinking below contents is refused", function()
	local bag = Bag.new(3)
	for _, id in { "a", "b", "c" } do
		bag:add(part(id))
	end
	bag:setCapacity(5)
	Test.truthy(bag:add(part("d")))
	Test.eq(pcall(function()
		bag:setCapacity(2)
	end), false)
end)

Test.done()
