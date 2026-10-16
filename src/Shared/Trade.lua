--!strict
-- Trading rules (spec section 5): a two-sided trade window as a state machine, anti-scam checks, and an atomic swap.
-- Pure logic over the players' data, so all of it is tested without Roblox; the server's TradeService connects it to
-- remotes and logs every trade (Shared/TradeLog).
--
-- Flow: both players put parts and pets in their offer -> each LOCKS in -> after a short delay each CONFIRMS -> the
-- server swaps everything in one step. Changing an offer at any point clears every lock and confirmation, so nothing
-- can be swapped under someone's feet. A lopsided trade needs the generous side to acknowledge the warning.

local Crafting = require("./Crafting")
local Economy = require("./Economy")
local Parts = require("./Parts")

local Trade = {}

export type Party = { userId: number, name: string }
export type Offer = { parts: { number }, pets: { number } }
export type Event = { t: number, e: string, u: number? }
export type Session = {
	id: string,
	a: Party,
	b: Party,
	offers: { [number]: Offer },
	locked: { [number]: boolean },
	confirmed: { [number]: boolean },
	acked: { [number]: boolean },
	state: string, -- "open" | "completed" | "cancelled" | "failed" | "expired"
	reason: string?,
	created: number,
	lastChange: number,
	lastActivity: number,
	events: { Event },
}
export type Data = Crafting.Data & Economy.Data
export type Settings = any

local MAX_EVENTS = 60

local function note(s: Session, now: number, e: string, userId: number?)
	if #s.events < MAX_EVENTS then
		table.insert(s.events, { t = now - s.created, e = e, u = userId })
	end
end

function Trade.new(cfg: Settings, id: string, a: Party, b: Party, now: number): Session
	local s: Session = {
		id = id,
		a = a,
		b = b,
		offers = { [a.userId] = { parts = {}, pets = {} }, [b.userId] = { parts = {}, pets = {} } },
		locked = {},
		confirmed = {},
		acked = {},
		state = "open",
		reason = nil,
		created = now,
		lastChange = now,
		lastActivity = now,
		events = {},
	}
	note(s, now, "open", nil)
	return s
end

function Trade.other(s: Session, userId: number): Party?
	if userId == s.a.userId then
		return s.b
	elseif userId == s.b.userId then
		return s.a
	end
	return nil
end

-- Who may trade at all: account age OR speed level (spec).
function Trade.eligible(cfg: Settings, accountAgeDays: number, level: number): (boolean, string)
	if not cfg.Trade.Enabled then
		return false, "trading is switched off right now"
	end
	if accountAgeDays >= cfg.Trade.MinAccountAgeDays or level >= cfg.Trade.MinLevel then
		return true, "ok"
	end
	return false, string.format("trading unlocks at level %d (or when your account is %d days old)", cfg.Trade.MinLevel, cfg.Trade.MinAccountAgeDays)
end

-- Value ----------------------------------------------------------------------------------------------------------------
local function findPart(data: Data, uid: number): Crafting.Item?
	for _, it in data.parts do
		if it.uid == uid then
			return it
		end
	end
	return nil
end

local function findPet(data: Data, uid: number): Crafting.Pet?
	for _, p in data.pets do
		if p.uid == uid then
			return p
		end
	end
	return nil
end

function Trade.partValue(cfg: Settings, item: Crafting.Item): number
	return Economy.sellValue(cfg, item)
end

-- A pet is worth its parts times a multiplier: building it consumed them and it cannot be taken apart.
function Trade.petValue(cfg: Settings, pet: Crafting.Pet): number
	local sum = 0.0
	for _, item in pet.slots do
		sum += Economy.sellValue(cfg, item)
	end
	return sum * cfg.Trade.PetValueMultiplier
end

-- Validation ----------------------------------------------------------------------------------------------------------
local function isArrayOfNumbers(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k, x in v do
		n += 1
		if type(k) ~= "number" or type(x) ~= "number" or x ~= x then
			return false
		end
	end
	return n == #v
end

-- Checks an offer against what the player really owns right now. Returns true or false and why.
function Trade.checkOffer(cfg: Settings, data: Data, partUids: any, petUids: any): (boolean, string)
	if not isArrayOfNumbers(partUids) or not isArrayOfNumbers(petUids) then
		return false, "invalid offer"
	end
	if #partUids + #petUids > cfg.Trade.MaxItemsPerSide then
		return false, string.format("at most %d items per side", cfg.Trade.MaxItemsPerSide)
	end
	local seen: { [number]: boolean } = {}
	for _, uid in partUids do
		local item = findPart(data, uid)
		if item == nil or seen[uid] then
			return false, "you do not have one of those parts"
		end
		seen[uid] = true
		if not Parts.isTradable(item.id) then
			return false, "one of those parts cannot be traded"
		end
	end
	local seenPets: { [number]: boolean } = {}
	for _, uid in petUids do
		local pet = findPet(data, uid)
		if pet == nil or seenPets[uid] then
			return false, "you do not have one of those pets"
		end
		seenPets[uid] = true
		if table.find(data.equippedPets, uid) then
			return false, "unequip a pet before trading it"
		end
		for _, item in pet.slots do
			if not Parts.isTradable(item.id) then
				return false, "that pet has a part that cannot be traded"
			end
		end
	end
	return true, "ok"
end

-- The offered value of one side and whether the whole trade looks lopsided (spec: flag wildly lopsided trades).
export type Evaluation = { value: { [number]: number }, lopsided: boolean, giver: number?, ratio: number }

function Trade.evaluate(cfg: Settings, s: Session, datas: { [number]: Data }): Evaluation
	local value: { [number]: number } = {}
	for _, party in { s.a, s.b } do
		local data = datas[party.userId]
		local total = 0.0
		local offer = s.offers[party.userId]
		if data then
			for _, uid in offer.parts do
				local item = findPart(data, uid)
				if item then
					total += Trade.partValue(cfg, item)
				end
			end
			for _, uid in offer.pets do
				local pet = findPet(data, uid)
				if pet then
					total += Trade.petValue(cfg, pet)
				end
			end
		end
		value[party.userId] = total
	end
	local va, vb = value[s.a.userId], value[s.b.userId]
	local giver: number? = nil
	local high, low = math.max(va, vb), math.min(va, vb)
	if high > low then
		giver = if va > vb then s.a.userId else s.b.userId
	end
	local ratio = if low <= 0 then (if high > 0 then math.huge else 1) else high / low
	local lopsided = giver ~= nil and ratio >= cfg.Trade.LopsidedRatio and high - low >= cfg.Trade.LopsidedMinDifference
	return { value = value, lopsided = lopsided, giver = if lopsided then giver else nil, ratio = ratio }
end

-- Window actions ------------------------------------------------------------------------------------------------------
local function resetAgreement(s: Session, now: number)
	s.locked = {}
	s.confirmed = {}
	s.acked = {}
	s.lastChange = now
end

local function isParty(s: Session, userId: number): boolean
	return userId == s.a.userId or userId == s.b.userId
end

-- Replace one side's offer. Any change clears every lock and confirmation.
function Trade.setOffer(cfg: Settings, s: Session, userId: number, data: Data, partUids: any, petUids: any, now: number): (boolean, string)
	if s.state ~= "open" or not isParty(s, userId) then
		return false, "this trade is closed"
	end
	local ok, why = Trade.checkOffer(cfg, data, partUids, petUids)
	if not ok then
		return false, why
	end
	s.offers[userId] = { parts = table.clone(partUids), pets = table.clone(petUids) }
	resetAgreement(s, now)
	s.lastActivity = now
	note(s, now, "offer", userId)
	return true, "ok"
end

local function itemCount(s: Session): number
	local n = 0
	for _, o in s.offers do
		n += #o.parts + #o.pets
	end
	return n
end

function Trade.lock(s: Session, userId: number, now: number): (boolean, string)
	if s.state ~= "open" or not isParty(s, userId) then
		return false, "this trade is closed"
	end
	if itemCount(s) == 0 then
		return false, "put something in the trade first"
	end
	s.locked[userId] = true
	s.lastActivity = now
	note(s, now, "lock", userId)
	return true, "ok"
end

-- Unlocking clears the other side's lock and everyone's confirmation too.
function Trade.unlock(s: Session, userId: number, now: number): (boolean, string)
	if s.state ~= "open" or not isParty(s, userId) then
		return false, "this trade is closed"
	end
	resetAgreement(s, now)
	s.lastActivity = now
	note(s, now, "unlock", userId)
	return true, "ok"
end

function Trade.bothLocked(s: Session): boolean
	return s.locked[s.a.userId] == true and s.locked[s.b.userId] == true
end

-- Seconds until confirming is allowed (0 = now): the delay after the last change.
function Trade.confirmWait(cfg: Settings, s: Session, now: number): number
	return math.max(0, cfg.Trade.ConfirmDelay - (now - s.lastChange))
end

-- Confirm after both have locked. `ack` is the player's explicit "I understand this looks lopsided" tap, required
-- from the side that gives much more than it gets.
function Trade.confirm(cfg: Settings, s: Session, userId: number, ack: boolean, evaluation: Evaluation, now: number): (boolean, string)
	if s.state ~= "open" or not isParty(s, userId) then
		return false, "this trade is closed"
	end
	if not Trade.bothLocked(s) then
		return false, "both players must lock in first"
	end
	if Trade.confirmWait(cfg, s, now) > 0 then
		return false, "wait a moment and check the trade again"
	end
	if evaluation.lopsided and evaluation.giver == userId and not ack then
		return false, "this trade looks lopsided: you give much more than you get"
	end
	if evaluation.lopsided and evaluation.giver == userId then
		s.acked[userId] = true
	end
	s.confirmed[userId] = true
	s.lastActivity = now
	note(s, now, "confirm", userId)
	return true, "ok"
end

function Trade.ready(s: Session): boolean
	return s.state == "open" and s.confirmed[s.a.userId] == true and s.confirmed[s.b.userId] == true
end

function Trade.close(s: Session, state: string, reason: string, now: number)
	if s.state == "open" then
		s.state = state
		s.reason = reason
		note(s, now, state, nil)
	end
end

function Trade.expired(cfg: Settings, s: Session, now: number): boolean
	return s.state == "open" and now - s.lastActivity > cfg.Trade.IdleSeconds
end

-- The swap -------------------------------------------------------------------------------------------------------------
-- Everything a side gives, as copies, for the log and the UI.
export type Gave = { parts: { Crafting.Item }, pets: { Crafting.Pet } }

local function cloneItem(item: Crafting.Item): Crafting.Item
	return { uid = item.uid, id = item.id, tier = item.tier, stats = table.clone(item.stats) }
end

function Trade.gave(s: Session, userId: number, data: Data): Gave
	local out: Gave = { parts = {}, pets = {} }
	for _, uid in s.offers[userId].parts do
		local item = findPart(data, uid)
		if item then
			table.insert(out.parts, cloneItem(item))
		end
	end
	for _, uid in s.offers[userId].pets do
		local pet = findPet(data, uid)
		if pet then
			local slots: { [string]: Crafting.Item } = {}
			for socket, item in pet.slots do
				slots[socket] = cloneItem(item)
			end
			table.insert(out.pets, { uid = pet.uid, slots = slots })
		end
	end
	return out
end

local function newUid(data: Data): number
	local uid = data.nextUid
	data.nextUid += 1
	return uid
end

-- Re-checks both offers and, if everything is still valid, swaps the items in one step. Nothing is changed unless the
-- whole trade can happen (all or nothing). Received items get fresh ids in the receiver's data, and the receiver's
-- Part Index records them. Call only when Trade.ready(s).
function Trade.execute(cfg: Settings, s: Session, datas: { [number]: Data }, now: number): (boolean, string)
	if not Trade.ready(s) then
		return false, "the trade is not confirmed by both players"
	end
	local da, db = datas[s.a.userId], datas[s.b.userId]
	if da == nil or db == nil then
		return false, "a player's data is not available"
	end
	for _, party in { s.a, s.b } do
		local offer = s.offers[party.userId]
		local ok, why = Trade.checkOffer(cfg, datas[party.userId], offer.parts, offer.pets)
		if not ok then
			return false, party.name .. ": " .. why
		end
	end
	local gaveA, gaveB = Trade.gave(s, s.a.userId, da), Trade.gave(s, s.b.userId, db)

	local function removeFrom(data: Data, offer: Offer)
		local dropParts: { [number]: boolean } = {}
		for _, uid in offer.parts do
			dropParts[uid] = true
		end
		local keptParts: { Crafting.Item } = {}
		for _, it in data.parts do
			if not dropParts[it.uid] then
				table.insert(keptParts, it)
			end
		end
		data.parts = keptParts
		local dropPets: { [number]: boolean } = {}
		for _, uid in offer.pets do
			dropPets[uid] = true
		end
		local keptPets: { Crafting.Pet } = {}
		for _, p in data.pets do
			if not dropPets[p.uid] then
				table.insert(keptPets, p)
			end
		end
		data.pets = keptPets
	end

	local function giveTo(data: Data, gave: Gave)
		for _, item in gave.parts do
			local copy: Crafting.Item = { uid = newUid(data), id = item.id, tier = item.tier, stats = table.clone(item.stats) }
			table.insert(data.parts, copy)
			Crafting.noteIndex(data, copy.id, copy.tier, now)
		end
		for _, pet in gave.pets do
			local slots: { [string]: Crafting.Item } = {}
			for socket, item in pet.slots do
				local copy: Crafting.Item = { uid = newUid(data), id = item.id, tier = item.tier, stats = table.clone(item.stats) }
				slots[socket] = copy
				Crafting.noteIndex(data, copy.id, copy.tier, now)
			end
			table.insert(data.pets, { uid = newUid(data), slots = slots })
		end
	end

	removeFrom(da, s.offers[s.a.userId])
	removeFrom(db, s.offers[s.b.userId])
	giveTo(db, gaveA)
	giveTo(da, gaveB)
	s.state = "completed"
	s.reason = "completed"
	note(s, now, "completed", nil)
	return true, "ok"
end

return Trade
