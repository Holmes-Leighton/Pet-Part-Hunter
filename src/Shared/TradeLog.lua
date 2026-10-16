--!strict
-- Trade records for the backend log (spec section 9: "log every trade"). Pure functions that turn a trade session
-- into a plain, JSON-safe record: who traded, exactly which parts and pets (ids, tiers, stats), their value, the
-- lopsided flag, the outcome and a timeline of what each player did. The server's TradeLogger stores the records;
-- keeping the shape here means it is tested and stays stable for the dashboard and for support investigations.
--
-- Records are never edited after being written. Cancelled, expired and failed trades are logged too, because the
-- pattern of attempts (not only the completed swaps) is how scams are spotted.

local Crafting = require("./Crafting")
local Trade = require("./Trade")

local TradeLog = {}

-- uid is the giver's id for the item and stats are exact (not rounded): together they let a crashed trade be finished
-- from the record alone (Shared/TradeRecovery).
export type ItemRecord = { uid: number, id: string, tier: number, stats: { speed: number, bag: number, coin: number, luck: number } }
export type PetRecord = { uid: number, slots: { [string]: ItemRecord } }
export type SideRecord = { name: string, value: number, parts: { ItemRecord }, pets: { PetRecord } }
export type Record = {
	v: number, -- record format version
	id: string,
	t: number, -- epoch seconds the trade ended
	started: number, -- epoch seconds the window opened
	duration: number,
	status: string, -- completed | cancelled | expired | failed
	reason: string,
	job: string, -- server job id, to find the server's other logs
	a: number, -- user ids
	b: number,
	sides: { [string]: SideRecord }, -- keyed by the user id as a string (JSON object keys must be strings)
	lopsided: boolean,
	ratio: number, -- value ratio, capped so it stays JSON-safe
	flags: { string },
	events: { { t: number, e: string, u: number? } },
}

TradeLog.VERSION = 1

local function round2(v: number): number
	return math.floor(v * 100 + 0.5) / 100
end

local function itemRecord(item: Crafting.Item): ItemRecord
	return {
		uid = item.uid,
		id = item.id,
		tier = item.tier,
		stats = { speed = item.stats.speed, bag = item.stats.bag, coin = item.stats.coin, luck = item.stats.luck },
	}
end

-- Builds the record for a finished trade window. `gave` is what each side put in (copies taken before the swap),
-- `evaluation` is Trade.evaluate, `startedEpoch`/`endedEpoch` are real clock times and `job` the server's job id.
function TradeLog.build(
	s: Trade.Session,
	gave: { [number]: Trade.Gave },
	evaluation: Trade.Evaluation,
	startedEpoch: number,
	endedEpoch: number,
	job: string,
	flags: { string }?
): Record
	local sides: { [string]: SideRecord } = {}
	for _, party in { s.a, s.b } do
		local g = gave[party.userId] or { parts = {}, pets = {} }
		local parts: { ItemRecord } = {}
		for _, item in g.parts do
			table.insert(parts, itemRecord(item))
		end
		local pets: { PetRecord } = {}
		for _, pet in g.pets do
			local slots: { [string]: ItemRecord } = {}
			for socket, item in pet.slots do
				slots[socket] = itemRecord(item)
			end
			table.insert(pets, { uid = pet.uid, slots = slots })
		end
		sides[tostring(party.userId)] = { name = party.name, value = round2(evaluation.value[party.userId] or 0), parts = parts, pets = pets }
	end
	local allFlags = if flags then table.clone(flags) else {}
	if evaluation.lopsided then
		table.insert(allFlags, "lopsided")
		if s.acked[evaluation.giver :: number] then
			table.insert(allFlags, "lopsided_acknowledged")
		end
	end
	return {
		v = TradeLog.VERSION,
		id = s.id,
		t = endedEpoch,
		started = startedEpoch,
		duration = math.max(0, endedEpoch - startedEpoch),
		status = s.state,
		reason = s.reason or "",
		job = job,
		a = s.a.userId,
		b = s.b.userId,
		sides = sides,
		lopsided = evaluation.lopsided,
		ratio = math.min(round2(evaluation.ratio), 1e6), -- an empty side makes the ratio infinite, which JSON cannot hold
		flags = allFlags,
		events = s.events,
	}
end

-- The DataStore key for a record: sorts by time and stays unique per trade.
function TradeLog.key(rec: Record): string
	return string.format("T%011d_%s", rec.t, rec.id)
end

-- The key of the record that supersedes this one when a trade was logged as completed but the swap was then rejected
-- (same time, id + "_f"). Recovery checks it before finishing a committed trade.
function TradeLog.supersededKey(rec: Record): string
	return string.format("T%011d_%s_f", rec.t, rec.id)
end

-- A short per-player index entry, so one player's trade history is a single lookup instead of a scan.
export type IndexEntry = { id: string, t: number, s: string, w: number, v: number, l: boolean }

function TradeLog.indexEntry(rec: Record, userId: number): IndexEntry
	local other = if userId == rec.a then rec.b else rec.a
	local mine = rec.sides[tostring(userId)]
	return { id = rec.id, t = rec.t, s = rec.status, w = other, v = if mine then mine.value else 0, l = rec.lopsided }
end

function TradeLog.indexKey(userId: number): string
	return "P" .. userId
end

-- Adds an entry to a player's index (newest last), keeping only the most recent `max`.
function TradeLog.addToIndex(list: any, entry: IndexEntry, max: number): { IndexEntry }
	local out: { IndexEntry } = {}
	if type(list) == "table" then
		for _, e in list do
			if type(e) == "table" and type(e.id) == "string" and e.id ~= entry.id then
				table.insert(out, e)
			end
		end
	end
	table.insert(out, entry)
	while #out > max do
		table.remove(out, 1)
	end
	return out
end

-- "Unusual trade volume" (spec section 9): true when a player has completed more than `perHour` trades in the past
-- hour. Mutates `times` (their completed-trade timestamps), dropping the old ones.
function TradeLog.volumeFlag(times: { number }, now: number, perHour: number): boolean
	local recent: { number } = {}
	for _, t in times do
		if now - t < 3600 then
			table.insert(recent, t)
		end
	end
	table.clear(times)
	for _, t in recent do
		table.insert(times, t)
	end
	return #times > perHour
end

-- A one-line summary for the Studio output and quick scanning in the dashboard.
function TradeLog.summary(rec: Record): string
	local a, b = rec.sides[tostring(rec.a)], rec.sides[tostring(rec.b)]
	return string.format(
		"[trade %s] %s: %s (%d) gave %d part(s)/%d pet(s) worth %.0f, %s (%d) gave %d part(s)/%d pet(s) worth %.0f%s",
		rec.id, rec.status, a.name, rec.a, #a.parts, #a.pets, a.value, b.name, rec.b, #b.parts, #b.pets, b.value,
		if #rec.flags > 0 then " flags=" .. table.concat(rec.flags, ",") else ""
	)
end

return TradeLog
