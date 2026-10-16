--!strict
-- Events (spec section 8). An event is a plain data record, so a new event never needs a code update: admins create
-- one in the admin panel, it is stored, and every server picks it up. This module is the pure part: what a valid record
-- looks like (events come from admins, so every field is range-checked), which events are active at a time, what their
-- modifiers add up to, how they change an area's part pool, and the community goal counter.
--
-- Event types from the spec map onto the fields of one record:
--   * limited-time area  -> `area` (a new maze, themed chaser) plus `spawn.parts` (exclusive parts)
--   * boost weekend      -> `modifiers` (luck, coins, speed gain, slower chaser)
--   * chaser variant     -> a `chaser` modifier above 1 (faster) with better `spawn` parts
--   * community goal     -> `goal` (the whole server collects N parts for a shared reward)
--   * chaos event        -> `chaos` (a short effect run by an admin)

local Parts = require("./Parts")

local Events = {}

export type Modifier = { kind: string, mult: number?, add: number? }
export type SpawnOverride = { weight: number, areas: { string }?, parts: { Parts.EventPart } }
export type AreaDef = {
	name: string,
	seed: number,
	width: number,
	height: number,
	exitCount: number,
	minExitSeparation: number,
	spawnCells: number,
	activeParts: number,
	expectedWalk: number,
	chaserMult: number,
	poolLike: string, -- an existing area whose rarity mix this one copies
}
export type Goal = { target: number, rewardCoins: number }
export type Chaos = { kind: string, value: number? }
export type Event = {
	id: string,
	name: string,
	start: number, -- epoch seconds
	["end"]: number,
	announce: string?,
	modifiers: { Modifier }?,
	spawn: SpawnOverride?,
	area: AreaDef?,
	goal: Goal?,
	chaos: Chaos?,
	tradable: boolean?,
}

local MODIFIER_LIMITS: { [string]: { field: string, min: number, max: number } } = {
	luck = { field = "add", min = 0, max = 500 }, -- +% luck, so 2x luck is +100
	coins = { field = "mult", min = 0.1, max = 10 },
	speed = { field = "mult", min = 0.1, max = 10 }, -- multiplier on Speed gained on pads
	chaser = { field = "mult", min = 0.2, max = 3 }, -- below 1 = a slower chaser, above 1 = an enraged one
}
local CHAOS_KINDS: { [string]: { min: number, max: number } } = {
	gravity = { min = 20, max = 196.2 }, -- workspace gravity; the normal value is 196.2
	coinRain = { min = 1, max = 100000 }, -- coins to everyone present
	announce = { min = 0, max = 0 },
}
local MAX_DURATION = 60 * 86400
local MAX_PARTS = 40

local function isNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function validName(v: any, pattern: string, maxLen: number): boolean
	return type(v) == "string" and #v >= 1 and #v <= maxLen and string.match(v, pattern) ~= nil
end

local function areaNames(cfg: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, a in cfg.Areas do
		set[a.name] = true
	end
	return set
end

-- Checks an event record. Returns true, or false and what is wrong. Nothing in a stored or admin-made event is
-- trusted: this runs on every record when it is saved and when it is loaded.
function Events.validate(cfg: any, ev: any): (boolean, string)
	if type(ev) ~= "table" then
		return false, "not an event"
	end
	if not validName(ev.id, "^[%w_%-]+$", 40) then
		return false, "id must be 1-40 letters, numbers, - or _"
	end
	if type(ev.name) ~= "string" or #ev.name < 1 or #ev.name > 40 then
		return false, "name must be 1-40 characters"
	end
	if not isNumber(ev.start) or not isNumber(ev["end"]) or ev["end"] <= ev.start then
		return false, "end must be after start"
	end
	if ev["end"] - ev.start > MAX_DURATION then
		return false, "events can run at most 60 days"
	end
	if ev.announce ~= nil and (type(ev.announce) ~= "string" or #ev.announce > 120) then
		return false, "announcement is at most 120 characters"
	end
	local areas = areaNames(cfg)

	if ev.modifiers ~= nil then
		if type(ev.modifiers) ~= "table" or #ev.modifiers > 8 then
			return false, "at most 8 modifiers"
		end
		for _, m in ev.modifiers do
			local limits = if type(m) == "table" then MODIFIER_LIMITS[m.kind] else nil
			if limits == nil then
				return false, "unknown modifier"
			end
			local v = m[limits.field]
			if not isNumber(v) or v < limits.min or v > limits.max then
				return false, string.format("%s %s must be between %s and %s", tostring(m.kind), limits.field, tostring(limits.min), tostring(limits.max))
			end
		end
	end

	if ev.spawn ~= nil then
		local sp = ev.spawn
		if type(sp) ~= "table" or not isNumber(sp.weight) or sp.weight < 0 or sp.weight > 0.9 then
			return false, "spawn weight must be 0 to 0.9"
		end
		if type(sp.parts) ~= "table" or #sp.parts < 1 or #sp.parts > MAX_PARTS then
			return false, "spawn needs 1-" .. MAX_PARTS .. " parts"
		end
		for _, p in sp.parts do
			if type(p) ~= "table" or not validName(p.species, "^%a[%w]*$", 20) or table.find(Parts.Slots, p.slot) == nil or not areas[p.rarity] then
				return false, "an event part needs a species name, a slot and a rarity"
			end
		end
		if sp.areas ~= nil then
			if type(sp.areas) ~= "table" then
				return false, "spawn areas must be a list"
			end
			for _, a in sp.areas do
				if not areas[a] and not (ev.area and ev.area.name == a) then
					return false, "unknown area " .. tostring(a)
				end
			end
		end
	end

	if ev.area ~= nil then
		local a = ev.area
		if type(a) ~= "table" or not validName(a.name, "^%a[%w]*$", 20) or areas[a.name] then
			return false, "event area needs a new name"
		end
		local function inRange(v: any, lo: number, hi: number): boolean
			return isNumber(v) and v >= lo and v <= hi
		end
		if not (inRange(a.seed, 1, 1e6) and inRange(a.width, 6, 16) and inRange(a.height, 6, 16) and inRange(a.exitCount, 1, 4)
			and inRange(a.minExitSeparation, 2, 20) and inRange(a.spawnCells, 10, 80) and inRange(a.activeParts, 1, 10)
			and inRange(a.expectedWalk, 8, 60) and inRange(a.chaserMult, 0.3, 2)) then
			return false, "event area numbers are out of range"
		end
		if not areas[a.poolLike] then
			return false, "event area poolLike must be an existing area"
		end
		if a.spawnCells < a.activeParts * 2 then
			return false, "event area needs at least twice as many spawn cells as active parts"
		end
	end

	if ev.goal ~= nil then
		local g = ev.goal
		if type(g) ~= "table" or not isNumber(g.target) or g.target < 1 or g.target > 100000 or g.target % 1 ~= 0 then
			return false, "goal target must be a whole number up to 100000"
		end
		if not isNumber(g.rewardCoins) or g.rewardCoins < 0 or g.rewardCoins > 1000000 then
			return false, "goal reward must be 0 to 1000000 coins"
		end
	end

	if ev.chaos ~= nil then
		local c = ev.chaos
		local limits = if type(c) == "table" then CHAOS_KINDS[c.kind] else nil
		if limits == nil then
			return false, "unknown chaos effect"
		end
		if c.kind ~= "announce" and (not isNumber(c.value) or c.value < limits.min or c.value > limits.max) then
			return false, string.format("%s value must be between %s and %s", tostring(c.kind), tostring(limits.min), tostring(limits.max))
		end
	end

	if ev.tradable ~= nil and type(ev.tradable) ~= "boolean" then
		return false, "tradable must be true or false"
	end
	return true, "ok"
end

-- What is running ---------------------------------------------------------------------------------------------------
function Events.isActive(ev: Event, now: number): boolean
	return now >= ev.start and now < ev["end"]
end

function Events.active(list: { Event }, now: number): { Event }
	local out: { Event } = {}
	for _, ev in list do
		if Events.isActive(ev, now) then
			table.insert(out, ev)
		end
	end
	table.sort(out, function(a: Event, b: Event)
		return if a.start ~= b.start then a.start < b.start else a.id < b.id
	end)
	return out
end

-- A string that changes exactly when the set of active events changes (used to notice starts and stops).
function Events.signature(active: { Event }): string
	local ids = {}
	for _, ev in active do
		table.insert(ids, ev.id)
	end
	table.sort(ids)
	return table.concat(ids, ",")
end

export type Mods = { luckAdd: number, coins: number, chaser: number, speed: number }

-- The combined effect of a set of active events: luck adds up, the rest multiply.
function Events.aggregate(active: { Event }): Mods
	local mods: Mods = { luckAdd = 0, coins = 1, chaser = 1, speed = 1 }
	for _, ev in active do
		for _, m in ev.modifiers or {} do
			if m.kind == "luck" then
				mods.luckAdd += m.add or 0
			elseif m.kind == "coins" then
				mods.coins *= m.mult or 1
			elseif m.kind == "chaser" then
				mods.chaser *= m.mult or 1
			elseif m.kind == "speed" then
				mods.speed *= m.mult or 1
			end
		end
	end
	return mods
end

-- Spawn pools ---------------------------------------------------------------------------------------------------------
-- The part templates for an area while events are active: the normal pool scaled down, with each event's exclusive
-- parts taking their share. `base` is the area's normal templates (weights add up to about 1).
function Events.templates(base: { Parts.Template }, active: { Event }, areaName: string): { Parts.Template }
	local extra: { Parts.Template } = {}
	local taken = 0.0
	for _, ev in active do
		local sp = ev.spawn
		if sp and sp.weight > 0 and (sp.areas == nil or table.find(sp.areas, areaName) ~= nil) then
			local each = sp.weight / #sp.parts
			for _, p in sp.parts do
				table.insert(extra, { species = p.species, slot = p.slot, rarity = p.rarity, weight = each })
			end
			taken += sp.weight
		end
	end
	if #extra == 0 then
		return base
	end
	taken = math.min(taken, 0.95)
	local out: { Parts.Template } = {}
	for _, t in base do
		table.insert(out, { species = t.species, slot = t.slot, rarity = t.rarity, weight = (t.weight or 1) * (1 - taken) })
	end
	for _, t in extra do
		table.insert(out, t)
	end
	return out
end

-- Registers an event's exclusive parts in the part table so they can be held, saved and shown. Safe to repeat.
function Events.registerParts(ev: Event): (boolean, string)
	if ev.spawn == nil then
		return true, "ok"
	end
	return Parts.registerEvent(ev.id, ev.spawn.parts, ev.tradable)
end

-- The area definition for an event area, in the shape Config.Areas uses, so the normal area code can build it.
function Events.areaDef(ev: Event): any?
	local a = ev.area
	if a == nil then
		return nil
	end
	return {
		name = a.name,
		seed = a.seed,
		width = a.width,
		height = a.height,
		exitCount = a.exitCount,
		minExitSeparation = a.minExitSeparation,
		spawnCells = a.spawnCells,
		activeParts = a.activeParts,
		expectedWalk = a.expectedWalk,
		poolLike = a.poolLike,
		chaserMult = a.chaserMult,
		event = ev.id,
	}
end

-- Community goal ---------------------------------------------------------------------------------------------------------
-- The whole server works towards one count (spec: "the whole server collects a set number of parts for a shared
-- reward"). Everyone who contributed at least once when it completes shares the reward.
export type GoalState = { progress: number, contributors: { [number]: number }, completed: boolean }

function Events.newGoal(): GoalState
	return { progress = 0, contributors = {}, completed = false }
end

-- Adds progress for a player. Returns true exactly once: the moment the target is reached.
function Events.addProgress(goal: Goal, state: GoalState, userId: number, n: number): boolean
	if state.completed or n <= 0 then
		return false
	end
	state.progress = math.min(goal.target, state.progress + n)
	state.contributors[userId] = (state.contributors[userId] or 0) + n
	if state.progress >= goal.target then
		state.completed = true
		return true
	end
	return false
end

-- Who gets the reward and how much each: every contributor, the same amount.
function Events.rewards(goal: Goal, state: GoalState): { [number]: number }
	local out: { [number]: number } = {}
	if state.completed then
		for userId in state.contributors do
			out[userId] = goal.rewardCoins
		end
	end
	return out
end

return Events
