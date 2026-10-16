--!strict
-- Crash-proof trades. A trade moves items between two players' profiles, which are saved separately, so a server crash
-- between the two saves could duplicate or lose items. This module makes that self-healing instead of a manual repair.
--
-- Each profile carries a small journal. The server's sequence for a trade is:
--   1. mark the trade PENDING in both profiles and save both (a durable note of intent),
--   2. write the trade record to the backend log. This is the COMMIT POINT: a record exists = the trade happened,
--   3. swap the items, mark the trade APPLIED in each profile (clearing pending) and save both.
-- When a profile loads with a pending trade, the server looks the record up:
--   * no completed record -> the trade never committed: the pending mark is dropped and nothing changes,
--   * a completed record  -> the trade did commit: this player's side is applied now (rolled forward) unless the profile
--     already shows it applied. Recovery is idempotent, so each player recovers on their own, in any order, and the
--     result is the same whichever of the two saves had made it to disk.

local Crafting = require("./Crafting")

local Recovery = {}

export type Pending = { id: string, key: string }
export type Journal = { pending: { Pending }, applied: { string } }

local MAX_APPLIED = 50 -- recent applied trade ids remembered (pending entries are resolved long before this matters)

export type ItemRec = { uid: number, id: string, tier: number, stats: { [string]: number } }
export type PetRec = { uid: number, slots: { [string]: ItemRec } }
export type SideRec = { parts: { ItemRec }, pets: { PetRec } }
export type RecordLike = { id: string, status: string, a: number, b: number, sides: { [string]: SideRec } }
export type Data = Crafting.Data & { tradeJournal: Journal }

function Recovery.newJournal(): Journal
	return { pending = {}, applied = {} }
end

function Recovery.isApplied(data: Data, id: string): boolean
	return table.find(data.tradeJournal.applied, id) ~= nil
end

local function removePending(j: Journal, id: string)
	for i = #j.pending, 1, -1 do
		if j.pending[i].id == id then
			table.remove(j.pending, i)
		end
	end
end

-- Step 1: note the intent before anything else happens.
function Recovery.begin(data: Data, id: string, key: string)
	removePending(data.tradeJournal, id)
	table.insert(data.tradeJournal.pending, { id = id, key = key })
end

-- The trade will not happen (it failed before the commit point): forget the note, change nothing else.
function Recovery.discard(data: Data, id: string)
	removePending(data.tradeJournal, id)
end

-- Step 3: this profile now reflects the trade. Clears the pending note and remembers the id.
function Recovery.settle(data: Data, id: string)
	local j = data.tradeJournal
	removePending(j, id)
	if not table.find(j.applied, id) then
		table.insert(j.applied, id)
	end
	while #j.applied > MAX_APPLIED do
		table.remove(j.applied, 1)
	end
end

function Recovery.pending(data: Data): { Pending }
	return table.clone(data.tradeJournal.pending)
end

-- A committed trade is one whose record says it completed. A later record with "_f" appended to the id (written when
-- the swap was rejected after the commit) supersedes it, which the caller checks before calling recover.
function Recovery.isCommitted(rec: RecordLike?): boolean
	return rec ~= nil and rec.status == "completed"
end

local function newUid(data: Data): number
	local uid = data.nextUid
	data.nextUid += 1
	return uid
end

local function addCopy(data: Data, item: ItemRec, now: number): Crafting.Item
	local copy: Crafting.Item = {
		uid = newUid(data),
		id = item.id,
		tier = item.tier,
		stats = { speed = item.stats.speed or 0, bag = item.stats.bag or 0, coin = item.stats.coin or 0, luck = item.stats.luck or 0 },
	}
	Crafting.noteIndex(data, copy.id, copy.tier, now)
	return copy
end

-- Applies one player's side of a committed trade to their profile: removes what they gave (matched by the item ids the
-- record kept, and only if the profile still has them) and adds what they received. Does nothing if the profile
-- already shows the trade applied. Returns "applied", "already" or "not_a_party".
function Recovery.recover(data: Data, rec: RecordLike, userId: number, now: number): string
	if userId ~= rec.a and userId ~= rec.b then
		return "not_a_party"
	end
	if Recovery.isApplied(data, rec.id) then
		removePending(data.tradeJournal, rec.id)
		return "already"
	end
	local otherId = if userId == rec.a then rec.b else rec.a
	local mine, theirs = rec.sides[tostring(userId)], rec.sides[tostring(otherId)]

	-- What this player gave: gone from their profile (if the stale profile still has it).
	local giveParts: { [number]: string } = {}
	for _, it in mine.parts do
		giveParts[it.uid] = it.id
	end
	local keptParts: { Crafting.Item } = {}
	for _, it in data.parts do
		if giveParts[it.uid] ~= it.id then
			table.insert(keptParts, it)
		end
	end
	data.parts = keptParts
	local givePets: { [number]: PetRec } = {}
	for _, p in mine.pets do
		givePets[p.uid] = p
	end
	local keptPets: { Crafting.Pet } = {}
	for _, pet in data.pets do
		local rec2 = givePets[pet.uid]
		local same = rec2 ~= nil
		if rec2 then
			for socket, item in pet.slots do
				same = same and rec2.slots[socket] ~= nil and rec2.slots[socket].id == item.id
			end
		end
		if same then
			-- A traded pet cannot still be equipped.
			local at = table.find(data.equippedPets, pet.uid)
			if at then
				table.remove(data.equippedPets, at)
			end
		else
			table.insert(keptPets, pet)
		end
	end
	data.pets = keptPets

	-- What this player received.
	for _, it in theirs.parts do
		table.insert(data.parts, addCopy(data, it, now))
	end
	for _, pet in theirs.pets do
		local slots: { [string]: Crafting.Item } = {}
		for socket, item in pet.slots do
			slots[socket] = addCopy(data, item, now)
		end
		table.insert(data.pets, { uid = newUid(data), slots = slots })
	end
	Recovery.settle(data, rec.id)
	return "applied"
end

return Recovery
