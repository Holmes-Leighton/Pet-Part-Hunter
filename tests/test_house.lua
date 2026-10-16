--!strict
local Test = require("./harness")
local House = require("../src/Shared/House")
local Profile = require("../src/Shared/Profile")
local Config = require("../src/Shared/Config")

local function fresh(): Profile.Data
	local d = Profile.load(nil, Config)
	d.coins = 100000
	return d
end

local function owned(d: Profile.Data, id: string, n: number?)
	Test.truthy(House.grant(Config, d, id, n or 1))
end

local function place(d: Profile.Data, id: string, x: number, y: number, r: number, c: number?): (House.Item?, string)
	return House.place(Config, d, id, x, y, r, c)
end

local function def(id: string): any
	return House.def(Config, id)
end

Test.case("the catalog: unique ids, a valid surface and a positive footprint, premium items are Robux-only", function()
	local seen: { [string]: boolean } = {}
	for _, f in Config.Furniture do
		Test.truthy(not seen[f.id], "duplicate " .. f.id)
		seen[f.id] = true
		Test.truthy(f.surface == "floor" or f.surface == "wall" or f.surface == "ceiling", f.id .. " surface")
		Test.truthy(f.w >= 1 and f.d >= 1, f.id .. " footprint")
		Test.truthy(if f.premium then f.robux ~= nil and f.coins == nil else f.coins ~= nil, f.id .. " pricing")
		-- Every item fits the room somewhere.
		local fits = false
		for x = 0, 15 do
			for y = 0, 15 do
				fits = fits or House.canPlace(Config, {}, f, x, y, 0, nil, nil)
			end
		end
		Test.truthy(fits, f.id .. " fits in an empty room")
	end
end)

Test.case("the starter room needs no furniture and starts empty", function()
	local d = fresh()
	Test.eq(#d.house.items, 0)
	Test.eq(d.furniture, {})
	Test.eq(House.limit(Config, d), 150)
end)

Test.case("buying: coins for basic furniture, not for premium, not without enough coins", function()
	local d = fresh()
	d.coins = 30
	Test.eq({ House.buy(Config, d, "Chair") }, { true, "ok" })
	Test.eq(d.coins, 5)
	Test.eq(d.furniture.Chair, 1)
	Test.eq({ House.buy(Config, d, "Chair") }, { false, "not enough coins" })
	Test.eq({ House.buy(Config, d, "CandySofa") }, { false, "that item is sold for Robux" })
	Test.eq({ House.buy(Config, d, "Nope") }, { false, "no such item" })
	Test.eq({ House.buy(Config, d, 5) }, { false, "no such item" })
	Test.eq(d.coins, 5)
end)

Test.case("placing consumes one owned item and snaps to the grid", function()
	local d = fresh()
	owned(d, "Table", 2)
	local item = place(d, "Table", 4, 4, 0)
	Test.truthy(item)
	Test.eq(d.furniture.Table, 1)
	Test.eq(#d.house.items, 1)
	Test.eq(place(d, "Chair", 1, 1, 0), nil, "not owned")
	Test.eq(select(2, place(d, "Chair", 1, 1, 0)), "you do not own that item")
	for _, bad in { 1.5, "3", 0 / 0, math.huge } do
		Test.eq(select(2, House.place(Config, d, "Table", bad, 4, 0, nil)), "invalid position")
	end
	Test.eq(d.furniture.Table, 1, "failed placements keep the stock")
end)

Test.case("bounds: nothing may hang over the edge of the room", function()
	local d = fresh()
	owned(d, "Table")
	Test.eq(select(2, place(d, "Table", -1, 0, 0)), "out of bounds")
	Test.eq(select(2, place(d, "Table", 15, 0, 0)), "out of bounds")
	Test.eq(select(2, place(d, "Table", 0, 15, 0)), "out of bounds")
	Test.truthy(place(d, "Table", 14, 0, 0), "flush against the east wall")
end)

Test.case("rotation swaps the footprint: a 2x3 bed fits one way and not the other", function()
	local d = fresh()
	owned(d, "Bed", 2)
	Test.eq(select(2, place(d, "Bed", 15, 0, 0)), "out of bounds")
	Test.eq(select(2, place(d, "Bed", 14, 0, 1)), "out of bounds", "turned: 3 wide, 2 deep")
	Test.truthy(place(d, "Bed", 13, 0, 1), "turned bed fits at x=13")
	Test.eq(select(2, place(d, "Bed", 0, 0, 4)), "invalid position", "only quarter turns")
	Test.eq(select(2, place(d, "Bed", 0, 0, -1)), "invalid position")
end)

Test.case("floor items cannot overlap each other, but touching is fine", function()
	local d = fresh()
	owned(d, "Table", 3)
	Test.truthy(place(d, "Table", 4, 4, 0))
	Test.eq(select(2, place(d, "Table", 5, 5, 0)), "overlaps another item")
	Test.eq(select(2, place(d, "Table", 4, 4, 0)), "overlaps another item")
	Test.truthy(place(d, "Table", 6, 4, 0), "adjacent")
end)

Test.case("surfaces are separate: a lamp can hang above a table; a painting can sit on a wall", function()
	local d = fresh()
	owned(d, "Table")
	owned(d, "Lamp")
	owned(d, "Painting")
	owned(d, "Fan")
	Test.truthy(place(d, "Table", 4, 4, 0))
	Test.truthy(place(d, "Lamp", 4, 4, 0), "ceiling above the table")
	Test.truthy(place(d, "Painting", 2, 1, 0), "north wall")
	Test.truthy(place(d, "Fan", 8, 8, 0), "ceiling elsewhere")
end)

Test.case("wall items: bounds along each wall, rows from the floor, one item per spot per wall", function()
	local d = fresh()
	owned(d, "Painting", 5)
	Test.eq(select(2, place(d, "Painting", 15, 1, 0)), "out of bounds", "too wide for the north wall end")
	Test.eq(select(2, place(d, "Painting", 2, 4, 0)), "out of bounds", "too tall: rows 4-5 of 5")
	Test.truthy(place(d, "Painting", 2, 3, 0))
	Test.eq(select(2, place(d, "Painting", 3, 3, 0)), "overlaps another item")
	Test.truthy(place(d, "Painting", 3, 3, 1), "same cells on the east wall are a different wall")
	Test.eq(select(2, place(d, "Painting", 0, 0, 5)), "invalid position")
end)

Test.case("the door and the floor in front of it stay clear", function()
	local d = fresh()
	owned(d, "Painting", 2)
	owned(d, "Clock")
	owned(d, "Chair", 3)
	local door = Config.House.Door
	Test.eq(select(2, place(d, "Painting", door.start, 1, door.wall)), "blocked by the door")
	Test.truthy(place(d, "Clock", door.start, door.rows, door.wall), "one row above the door is fine")
	Test.eq(select(2, place(d, "Chair", door.start + 1, Config.House.Depth - 1, 0)), "blocked by the door")
	Test.truthy(place(d, "Chair", door.start + 1, Config.House.Depth - door.clearance - 1, 0), "beyond the clear strip")
	Test.truthy(place(d, "Chair", door.start - 1, Config.House.Depth - 1, 0), "beside the door")
end)

Test.case("item limit: 150 placed items, raised by the house expansion pass", function()
	local d = fresh()
	d.passes = {}
	owned(d, "Plant", 400)
	local placed = 0
	local lastWhy = ""
	for y = 0, 15 do
		for x = 0, 15 do
			local item, why = place(d, "Plant", x, y, 0)
			if item then
				placed += 1
			else
				lastWhy = why
			end
		end
	end
	-- 256 cells minus the door strip (3 x 2) = 250 usable, so the limit is what stops us at 150.
	Test.eq(placed, 150)
	Test.eq(lastWhy, "item limit reached")
	d.passes.HouseExpansion = true
	Test.eq(House.limit(Config, d), 250)
	local more = 0
	for y = 0, 15 do
		for x = 0, 15 do
			if place(d, "Plant", x, y, 0) then
				more += 1
			end
		end
	end
	Test.eq(placed + more, 250)
end)

Test.case("moving checks the new spot but ignores the item itself", function()
	local d = fresh()
	owned(d, "Table", 2)
	local a = place(d, "Table", 4, 4, 0) :: House.Item
	local b = place(d, "Table", 8, 4, 0) :: House.Item
	Test.eq({ House.move(Config, d, a.uid, 4, 5, 0, nil) }, { true, "ok" }, "can overlap its own old spot")
	Test.eq(a.y, 5)
	Test.eq({ House.move(Config, d, a.uid, 7, 4, 0, nil) }, { false, "overlaps another item" })
	Test.eq(a.x, 4, "unchanged after a failed move")
	Test.eq({ House.move(Config, d, a.uid, -1, 0, 0, nil) }, { false, "out of bounds" })
	Test.eq({ House.move(Config, d, 9999, 0, 0, 0, nil) }, { false, "no such item" })
	Test.eq({ House.move(Config, d, b.uid, 8, 4, 1, 2) }, { true, "ok" }, "rotate in place and recolour")
	Test.eq({ b.r, b.c }, { 1, 2 })
	Test.eq({ House.move(Config, d, b.uid, 8, 4, 1, 99) }, { false, "invalid colour" })
end)

Test.case("moving a full house is still allowed (the limit is only for adding)", function()
	local d = fresh()
	owned(d, "Plant", 150)
	local first: House.Item? = nil
	for y = 0, 15 do
		for x = 0, 15 do
			local it = place(d, "Plant", x, y, 0)
			first = first or it
		end
	end
	Test.eq(#d.house.items, 150)
	local ok = false
	for y = 0, 15 do
		for x = 0, 15 do
			if not ok and House.move(Config, d, (first :: House.Item).uid, x, y, 0, nil) and (first :: House.Item).x == x and (first :: House.Item).y == y and not (x == 0 and y == 0) then
				ok = true
			end
		end
	end
	Test.eq(#d.house.items, 150)
end)

Test.case("deleting returns the item to the player, never loses it", function()
	local d = fresh()
	owned(d, "Sofa")
	local it = place(d, "Sofa", 2, 2, 0) :: House.Item
	Test.eq(d.furniture.Sofa, 0)
	Test.eq({ House.remove(Config, d, it.uid) }, { true, "ok" })
	Test.eq(d.furniture.Sofa, 1)
	Test.eq(#d.house.items, 0)
	Test.eq({ House.remove(Config, d, it.uid) }, { false, "no such item" })
	Test.eq(d.furniture.Sofa, 1, "a second delete cannot duplicate it")
end)

Test.case("premium items can be granted and placed, but are never coin purchases", function()
	local d = fresh()
	Test.eq(House.grant(Config, d, "CandySofa", 1), true)
	Test.truthy(place(d, "CandySofa", 2, 2, 0))
	Test.eq(House.grant(Config, d, "Nope", 1), false)
	Test.eq(House.grant(Config, d, "Chair", 0), false)
	Test.eq(House.grant(Config, d, "Chair", 1.5), false)
end)

Test.case("visitors: the owner always, others only if allowed, with a cap", function()
	local d = fresh()
	Test.truthy(House.canVisit(10, d.house, 10))
	Test.truthy(not House.canVisit(10, d.house, 11))
	Test.eq({ House.setAllowed(Config, d, 11, true) }, { true, "ok" })
	Test.eq({ House.setAllowed(Config, d, 11, true) }, { true, "ok" })
	Test.eq(#d.house.allow, 1, "no duplicates")
	Test.truthy(House.canVisit(10, d.house, 11))
	Test.eq({ House.setAllowed(Config, d, 11, false) }, { true, "ok" })
	Test.truthy(not House.canVisit(10, d.house, 11))
	for i = 1, Config.House.MaxVisitors do
		Test.truthy(House.setAllowed(Config, d, 100 + i, true))
	end
	Test.eq({ House.setAllowed(Config, d, 999, true) }, { false, "visitor list is full" })
	Test.eq({ House.setAllowed(Config, d, -3, true) }, { false, "invalid request" })
	Test.eq({ House.setAllowed(Config, d, 5, "yes") }, { false, "invalid request" })
end)

Test.case("a saved house round-trips through Profile.load", function()
	local d = fresh()
	owned(d, "Table")
	owned(d, "Lamp")
	owned(d, "Painting")
	owned(d, "Chair", 2)
	place(d, "Table", 4, 4, 1, 2)
	place(d, "Lamp", 4, 4, 0)
	place(d, "Painting", 2, 2, 3)
	House.setAllowed(Config, d, 42, true)
	local loaded = Profile.load(d, Config)
	Test.eq(loaded.house, d.house)
	Test.eq(loaded.furniture.Chair, 2)
	Test.truthy(loaded.nextUid > 3)
end)

Test.case("a damaged or hacked layout is repaired: bad items dropped and refunded, no duplicates", function()
	local d = fresh()
	owned(d, "Table")
	owned(d, "Chair")
	local t = place(d, "Table", 4, 4, 0) :: House.Item
	local c = place(d, "Chair", 8, 8, 0) :: House.Item
	local raw: any = Profile.load(d, Config)
	table.insert(raw.house.items, { uid = 500, id = "Table", x = 4, y = 4, r = 0, c = 0 }) -- overlaps the table
	table.insert(raw.house.items, { uid = 501, id = "Chair", x = 99, y = 0, r = 0, c = 0 }) -- out of bounds
	table.insert(raw.house.items, { uid = 502, id = "Nope", x = 1, y = 1, r = 0, c = 0 }) -- unknown item
	table.insert(raw.house.items, { uid = c.uid, id = "Plant", x = 1, y = 1, r = 0, c = 0 }) -- duplicate uid
	table.insert(raw.house.items, { uid = 503, id = "Plant", x = 1.5, y = 1, r = 0, c = 0 }) -- off the grid
	table.insert(raw.house.items, { uid = 504, id = "Plant", x = 1, y = 1, r = 0, c = 77 }) -- bad colour
	table.insert(raw.house.items, "junk")
	local fixed = Profile.load(raw, Config)
	Test.eq(#fixed.house.items, 2)
	local ids = { fixed.house.items[1].id, fixed.house.items[2].id }
	table.sort(ids)
	Test.eq(ids, { "Chair", "Table" })
	Test.eq(fixed.furniture.Table, 1, "the overlapping table was refunded")
	Test.eq(fixed.furniture.Chair, 1, "the out-of-bounds chair was refunded")
	Test.eq(fixed.furniture.Plant, 3, "three bad plants refunded (duplicate uid, off-grid, bad colour)")
	local seen: { [number]: boolean } = {}
	for _, it in fixed.house.items do
		Test.truthy(not seen[it.uid])
		seen[it.uid] = true
	end
	Test.truthy(fixed.nextUid > math.max(t.uid, c.uid))
end)

Test.case("loading enforces the item limit and the visitor cap", function()
	local d = fresh()
	local raw: any = { house = { items = {}, allow = {} } }
	for i = 1, 200 do
		raw.house.items[i] = { uid = i, id = "Plant", x = (i - 1) % 16, y = math.floor((i - 1) / 16), r = 0, c = 0 }
	end
	for i = 1, 20 do
		raw.house.allow[i] = i
	end
	local loaded = Profile.load(raw, Config)
	Test.truthy(#loaded.house.items <= 150)
	Test.eq(#loaded.house.allow, Config.House.MaxVisitors)
	local _ = d
end)

Test.case("a huge furniture count in a save is capped", function()
	local loaded = Profile.load({ furniture = { Chair = 1e12, Nope = 3, Plant = -4 } }, Config)
	Test.eq(loaded.furniture.Chair, 9999)
	Test.eq(loaded.furniture.Nope, nil)
	Test.eq(loaded.furniture.Plant, 0)
end)

Test.case("world positions: floor items stand on the floor, ceiling items hang from it, wall items touch their wall", function()
	local cell = Config.House.CellSize
	local x, y, z = House.worldCentre(Config, def("Table"), { x = 2, y = 3, r = 0 })
	Test.eq({ x, y, z }, { 3 * cell, 1.5, 4 * cell })
	local rx, _, rz = House.worldCentre(Config, def("Bed"), { x = 0, y = 0, r = 1 })
	Test.eq({ rx, rz }, { 1.5 * cell, 1 * cell }, "turned bed is 3 wide, 2 deep")
	local _, ly = House.worldCentre(Config, def("Lamp"), { x = 0, y = 0, r = 0 })
	Test.eq(ly, Config.House.WallRows * cell - def("Lamp").h / 2)
	local nx, ny, nz = House.worldCentre(Config, def("Painting"), { x = 2, y = 1, r = 0 })
	Test.eq({ nx, ny, nz }, { 3 * cell, 2 * cell, 0 }, "north wall z = 0")
	local _, _, sz = House.worldCentre(Config, def("Painting"), { x = 2, y = 1, r = 2 })
	Test.eq(sz, Config.House.Depth * cell, "south wall")
	local ex = House.worldCentre(Config, def("Painting"), { x = 2, y = 1, r = 1 })
	Test.eq(ex, Config.House.Width * cell, "east wall")
	local wx = House.worldCentre(Config, def("Painting"), { x = 2, y = 1, r = 3 })
	Test.eq(wx, 0, "west wall")
end)

Test.case("world boxes: right size, inside the room, wall items clear of the wall surface", function()
	local cell = Config.House.CellSize
	local W, D = Config.House.Width * cell, Config.House.Depth * cell
	local cx, cy, cz, sx, sy, sz = House.worldBox(Config, def("Bed"), { x = 0, y = 0, r = 1 })
	Test.eq({ sx, sy, sz }, { 3 * cell, 3, 2 * cell }, "turned bed is 3 wide and 2 deep")
	Test.eq({ cx, cz }, { 1.5 * cell, 1 * cell })
	Test.eq(cy, 1.5)
	-- A north wall painting: slab pushed into the room (+z), 2 cells wide, 2 rows tall.
	local px, py, pz, psx, psy, psz = House.worldBox(Config, def("Painting"), { x = 2, y = 1, r = 0 })
	Test.eq({ px, py, psx, psy, psz }, { 3 * cell, 2 * cell, 2 * cell, 2 * cell, Config.House.WallItemDepth })
	Test.truthy(pz - psz / 2 >= Config.House.WallThickness / 2, "does not poke into the wall")
	-- East wall: pushed to -x, thin in x, long in z.
	local ex, _, _, esx, _, esz = House.worldBox(Config, def("Painting"), { x = 2, y = 1, r = 1 })
	Test.eq({ esx, esz }, { Config.House.WallItemDepth, 2 * cell })
	Test.truthy(ex + esx / 2 <= W - Config.House.WallThickness / 2)
	-- Every valid placement of every item stays inside the room's outer box.
	for _, f in Config.Furniture do
		for r = 0, 3 do
			for x = 0, 15 do
				for y = 0, 15 do
					if House.canPlace(Config, {}, f, x, y, r, nil, nil) then
						local bx, by, bz, bsx, bsy, bsz = House.worldBox(Config, f, { x = x, y = y, r = r })
						Test.truthy(bx - bsx / 2 >= -0.01 and bx + bsx / 2 <= W + 0.01, f.id .. " x inside")
						Test.truthy(bz - bsz / 2 >= -0.01 and bz + bsz / 2 <= D + 0.01, f.id .. " z inside")
						Test.truthy(by - bsy / 2 >= -0.01 and by + bsy / 2 <= Config.House.WallRows * cell + 0.01, f.id .. " y inside")
					end
				end
			end
		end
	end
end)

Test.case("facing steps are unit steps that turn through all four directions", function()
	local seen: { [string]: boolean } = {}
	for r = 0, 3 do
		local x, z = House.facing(r)
		Test.eq(math.abs(x) + math.abs(z), 1)
		seen[x .. "," .. z] = true
	end
	Test.eq(seen["0,1"] and seen["-1,0"] and seen["0,-1"] and seen["1,0"], true)
end)

Test.done()
