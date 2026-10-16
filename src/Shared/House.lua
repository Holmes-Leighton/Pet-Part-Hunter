--!strict
-- Home building rules (spec section 2): the plot grid, where each kind of furniture may go, buying, placing,
-- moving, rotating, deleting, visitors and the compact saved layout. Pure logic over Config.House / Config.Furniture
-- and the player's data, so it is unit tested without Roblox. The client uses the same canPlace for its red/green
-- ghost preview, and the server re-checks every request: the client only ever asks.
--
-- Grid: the room is Width x Depth cells. Floor and ceiling items cover cells (x, y). Wall items sit on one of four
-- walls (0 = north z=0, 1 = east, 2 = south, 3 = west) at (cell along the wall, row from the floor). For floor and
-- ceiling items `r` is a quarter turn (0-3); for wall items `r` is the wall. A door on the south wall and a strip of
-- floor in front of it stay clear so a player can always get in and out.

local House = {}

export type Item = { uid: number, id: string, x: number, y: number, r: number, c: number }
export type HouseData = { version: number, items: { Item }, allow: { number } }
export type Data = {
	coins: number,
	passes: { [string]: boolean },
	nextUid: number,
	furniture: { [string]: number }, -- owned but not placed
	house: HouseData,
}
export type Settings = { House: any, Furniture: any }

function House.default(cfg: Settings): HouseData
	return { version = cfg.House.SchemaVersion, items = {}, allow = {} }
end

function House.def(cfg: Settings, id: string): any?
	for _, d in cfg.Furniture do
		if d.id == id then
			return d
		end
	end
	return nil
end

-- Footprint in cells after rotation. Wall items never rotate: their footprint is cells along the wall x rows.
function House.dims(def: any, r: number): (number, number)
	if def.surface ~= "wall" and r % 2 == 1 then
		return def.d, def.w
	end
	return def.w, def.d
end

local function isInt(v: any): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and v > -1e9 and v < 1e9
end

-- The surface and rectangle (exclusive end) an item would cover; nil when r is not valid for its surface.
function House.rect(def: any, x: number, y: number, r: number): (string?, number, number, number, number)
	if not isInt(r) or r < 0 or r > 3 then
		return nil, 0, 0, 0, 0
	end
	local w, d = House.dims(def, r)
	local key = if def.surface == "wall" then "wall" .. r else def.surface
	return key, x, y, x + w, y + d
end

local function wallLength(cfg: Settings, side: number): number
	return if side % 2 == 0 then cfg.House.Width else cfg.House.Depth
end

local function inBounds(cfg: Settings, key: string, x1: number, y1: number, x2: number, y2: number): boolean
	if x1 < 0 or y1 < 0 then
		return false
	end
	if key == "floor" or key == "ceiling" then
		return x2 <= cfg.House.Width and y2 <= cfg.House.Depth
	end
	local side = tonumber(string.sub(key, 5)) :: number
	return x2 <= wallLength(cfg, side) and y2 <= cfg.House.WallRows
end

type Rect = { key: string, x1: number, y1: number, x2: number, y2: number }

-- Space that must stay free: the door in its wall, and the floor strip in front of it.
function House.blocked(cfg: Settings): { Rect }
	local door = cfg.House.Door
	return {
		{ key = "wall" .. door.wall, x1 = door.start, y1 = 0, x2 = door.start + door.width, y2 = door.rows },
		{ key = "floor", x1 = door.start, y1 = cfg.House.Depth - door.clearance, x2 = door.start + door.width, y2 = cfg.House.Depth },
	}
end

local function overlaps(a: Rect, b: Rect): boolean
	return a.key == b.key and a.x1 < b.x2 and b.x1 < a.x2 and a.y1 < b.y2 and b.y1 < a.y2
end

-- Items allowed on the plot: the base limit, plus the house expansion pass.
function House.limit(cfg: Settings, data: { passes: { [string]: boolean } }): number
	return cfg.House.ItemLimit + (if data.passes.HouseExpansion then cfg.House.ExpansionBonus else 0)
end

-- Can `def` go at (x, y, r), given the items already placed? `ignoreUid` skips one item (when moving it).
function House.canPlace(cfg: Settings, items: { Item }, def: any, x: any, y: any, r: any, ignoreUid: number?, limit: number?): (boolean, string)
	if not (isInt(x) and isInt(y) and isInt(r)) then
		return false, "invalid position"
	end
	local key, x1, y1, x2, y2 = House.rect(def, x, y, r)
	if key == nil then
		return false, "invalid position"
	end
	if not inBounds(cfg, key, x1, y1, x2, y2) then
		return false, "out of bounds"
	end
	local mine: Rect = { key = key, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
	for _, b in House.blocked(cfg) do
		if overlaps(mine, b) then
			return false, "blocked by the door"
		end
	end
	local count = 0
	for _, it in items do
		if it.uid ~= ignoreUid then
			count += 1
			local other = House.def(cfg, it.id)
			if other then
				local k, ox1, oy1, ox2, oy2 = House.rect(other, it.x, it.y, it.r)
				if k and overlaps(mine, { key = k, x1 = ox1, y1 = oy1, x2 = ox2, y2 = oy2 }) then
					return false, "overlaps another item"
				end
			end
		end
	end
	if ignoreUid == nil and limit and count >= limit then
		return false, "item limit reached"
	end
	return true, "ok"
end

local function findItem(data: Data, uid: any): (Item?, number?)
	for i, it in data.house.items do
		if it.uid == uid then
			return it, i
		end
	end
	return nil, nil
end

local function validVariant(cfg: Settings, c: any): boolean
	return c == nil or (isInt(c) and c >= 0 and c < (cfg.House.Variants or 1))
end

-- Buy basic furniture with coins. Premium (Robux) items cannot be bought this way.
function House.buy(cfg: Settings, data: Data, id: any): (boolean, string)
	local def = if type(id) == "string" then House.def(cfg, id) else nil
	if def == nil then
		return false, "no such item"
	end
	if def.premium then
		return false, "that item is sold for Robux"
	end
	if data.coins < def.coins then
		return false, "not enough coins"
	end
	data.coins -= def.coins
	data.furniture[id] = (data.furniture[id] or 0) + 1
	return true, "ok"
end

-- Server-side grant (purchases, events). Used for Robux and event items.
function House.grant(cfg: Settings, data: Data, id: string, n: number): boolean
	if House.def(cfg, id) == nil or n < 1 or n % 1 ~= 0 then
		return false
	end
	data.furniture[id] = (data.furniture[id] or 0) + n
	return true
end

-- Place an owned item. Consumes one from the unplaced stock. All or nothing.
function House.place(cfg: Settings, data: Data, id: any, x: any, y: any, r: any, c: any): (Item?, string)
	local def = if type(id) == "string" then House.def(cfg, id) else nil
	if def == nil then
		return nil, "no such item"
	end
	if (data.furniture[id] or 0) < 1 then
		return nil, "you do not own that item"
	end
	if not validVariant(cfg, c) then
		return nil, "invalid colour"
	end
	local ok, why = House.canPlace(cfg, data.house.items, def, x, y, r, nil, House.limit(cfg, data))
	if not ok then
		return nil, why
	end
	data.furniture[id] -= 1
	local item: Item = { uid = data.nextUid, id = id, x = x, y = y, r = r, c = c or 0 }
	data.nextUid += 1
	table.insert(data.house.items, item)
	return item, "ok"
end

-- Move and/or rotate a placed item (and optionally change its colour). Nothing changes on failure.
function House.move(cfg: Settings, data: Data, uid: any, x: any, y: any, r: any, c: any): (boolean, string)
	local item = findItem(data, uid)
	if item == nil then
		return false, "no such item"
	end
	if not validVariant(cfg, c) then
		return false, "invalid colour"
	end
	local def = House.def(cfg, item.id)
	if def == nil then
		return false, "no such item"
	end
	local ok, why = House.canPlace(cfg, data.house.items, def, x, y, r, item.uid, nil)
	if not ok then
		return false, why
	end
	item.x, item.y, item.r = x, y, r
	if c ~= nil then
		item.c = c
	end
	return true, "ok"
end

-- Delete a placed item: it goes back to the player's stock, never lost (spec).
function House.remove(cfg: Settings, data: Data, uid: any): (boolean, string)
	local item, index = findItem(data, uid)
	if item == nil or index == nil then
		return false, "no such item"
	end
	table.remove(data.house.items, index)
	data.furniture[item.id] = (data.furniture[item.id] or 0) + 1
	return true, "ok"
end

-- Visitors ------------------------------------------------------------------------------------------------------
function House.setAllowed(cfg: Settings, data: Data, userId: any, allowed: any): (boolean, string)
	if not isInt(userId) or userId < 1 or type(allowed) ~= "boolean" then
		return false, "invalid request"
	end
	local list = data.house.allow
	local at = table.find(list, userId)
	if allowed then
		if at then
			return true, "ok"
		end
		if #list >= cfg.House.MaxVisitors then
			return false, "visitor list is full"
		end
		table.insert(list, userId)
	elseif at then
		table.remove(list, at)
	end
	return true, "ok"
end

-- The owner is always welcome; anyone else only if the owner allowed them.
function House.canVisit(ownerUserId: number, ownerHouse: HouseData, visitorUserId: number): boolean
	return ownerUserId == visitorUserId or table.find(ownerHouse.allow, visitorUserId) ~= nil
end

-- Saving and loading ----------------------------------------------------------------------------------------------
-- Re-validates a saved layout item by item, as if placing it again: anything that no longer fits (a hacked save, or a
-- later change to the room) is dropped and refunded to the stock instead of corrupting the plot. `claim(uid)` lets
-- the caller reserve unique ids. Returns the clean house plus the refunds by item id.
function House.load(cfg: Settings, raw: any, limit: number, claim: (number) -> boolean): (HouseData, { [string]: number })
	local out = House.default(cfg)
	local refunds: { [string]: number } = {}
	if type(raw) ~= "table" then
		return out, refunds
	end
	if type(raw.items) == "table" then
		for _, r in raw.items do
			if type(r) == "table" and type(r.id) == "string" and isInt(r.uid) and r.uid > 0 then
				local def = House.def(cfg, r.id)
				if def then
					local ok = isInt(r.x) and isInt(r.y) and isInt(r.r)
						and House.canPlace(cfg, out.items, def, r.x, r.y, r.r, nil, limit)
						and validVariant(cfg, r.c)
					if ok and claim(r.uid) then
						table.insert(out.items, { uid = r.uid, id = r.id, x = r.x, y = r.y, r = r.r, c = r.c or 0 })
					else
						refunds[r.id] = (refunds[r.id] or 0) + 1
					end
				end
			end
		end
	end
	if type(raw.allow) == "table" then
		for _, uid in raw.allow do
			if isInt(uid) and uid > 0 and #out.allow < cfg.House.MaxVisitors and not table.find(out.allow, uid) then
				table.insert(out.allow, uid)
			end
		end
	end
	return out, refunds
end

-- Geometry for building the room and its furniture in the world. Positions are relative to the plot corner, in studs,
-- at floor level (y = 0). Floor and wall pieces return their centre; ceiling pieces are placed under the ceiling.
function House.worldCentre(cfg: Settings, def: any, item: { x: number, y: number, r: number }): (number, number, number)
	local cell = cfg.House.CellSize
	local key, x1, y1, x2, y2 = House.rect(def, item.x, item.y, item.r)
	local cx, cy = (x1 + x2) / 2 * cell, (y1 + y2) / 2 * cell
	if key == "floor" then
		return cx, def.h / 2, cy
	elseif key == "ceiling" then
		local top = cfg.House.WallRows * cell
		return cx, top - def.h / 2, cy
	end
	-- Wall item: cx runs along the wall, cy is the height. Return world x, y, z for the wall it is on.
	local side = item.r
	local along, height = (x1 + x2) / 2 * cell, (y1 + y2) / 2 * cell
	local W, D = cfg.House.Width * cell, cfg.House.Depth * cell
	if side == 0 then
		return along, height, 0
	elseif side == 2 then
		return along, height, D
	elseif side == 1 then
		return W, height, along
	end
	return 0, height, along
end

return House
