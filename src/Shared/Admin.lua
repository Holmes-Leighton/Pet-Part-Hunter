--!strict
-- Admin rules (spec section 8): who is a mod, an admin or an owner, which role each command needs, and strict
-- validation of every command's arguments, plus the data operations the commands perform (grant and remove coins and
-- parts, snapshots and rollback). Pure logic, tested without Roblox. The server's AdminService enforces all of it:
-- admin commands are never trusted from the client, and a client claiming a role changes nothing.

local Crafting = require("./Crafting")
local Parts = require("./Parts")
local Profile = require("./Profile")

local Admin = {}

export type Role = "none" | "mod" | "admin" | "owner"

local RANK: { [string]: number } = { none = 0, mod = 1, admin = 2, owner = 3 }

-- Which role each command needs at minimum.
Admin.ACTIONS = {
	players = "mod",
	inspect = "mod",
	kick = "mod",
	announce = "mod",
	audit = "mod",
	event_list = "mod",
	tuning_get = "mod",
	snapshots = "admin",
	grant_coins = "admin",
	remove_coins = "admin",
	grant_part = "admin",
	remove_part = "admin",
	ban = "admin",
	unban = "admin",
	rollback = "admin",
	event_upsert = "admin",
	event_stop = "admin",
	tuning_set = "admin",
	trades = "admin",
	event_delete = "owner",
	tuning_reset = "owner",
} :: { [string]: string }

-- Roles --------------------------------------------------------------------------------------------------------------------
-- The highest role a person qualifies for: from the listed user ids, and from their rank in the admin group.
function Admin.roleFor(cfg: any, userId: number, groupRank: number?): Role
	local best = "none"
	local function raise(role: string)
		if RANK[role] > RANK[best] then
			best = role
		end
	end
	if table.find(cfg.Admin.Owners, userId) then
		raise("owner")
	end
	if table.find(cfg.Admin.Admins, userId) then
		raise("admin")
	end
	if table.find(cfg.Admin.Mods, userId) then
		raise("mod")
	end
	if cfg.Admin.GroupId ~= 0 and groupRank then
		local r = cfg.Admin.GroupRanks
		if groupRank >= r.Owner then
			raise("owner")
		elseif groupRank >= r.Admin then
			raise("admin")
		elseif groupRank >= r.Mod then
			raise("mod")
		end
	end
	return best :: Role
end

function Admin.can(role: string, action: string): boolean
	local needed = Admin.ACTIONS[action]
	return needed ~= nil and (RANK[role] or 0) >= RANK[needed]
end

-- Argument validation ----------------------------------------------------------------------------------------------------
local function isInt(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and v >= lo and v <= hi
end

local function text(v: any, maxLen: number): string?
	if type(v) ~= "string" then
		return nil
	end
	local cleaned = string.gsub(v, "[%c]", " ")
	cleaned = string.sub(cleaned, 1, maxLen)
	return cleaned
end

local function userId(v: any): boolean
	return isInt(v, 1, 1e12)
end

-- Checks a command and its arguments and returns the cleaned arguments, or false and why. Destructive commands need a
-- written reason, which goes into the audit log.
function Admin.validate(cfg: any, action: string, args: any): (boolean, any)
	if Admin.ACTIONS[action] == nil then
		return false, "unknown command"
	end
	if type(args) ~= "table" then
		args = {}
	end
	local out: { [string]: any } = {}
	local reasonNeeded = action == "kick" or action == "ban" or action == "remove_coins" or action == "remove_part" or action == "rollback"
		or action == "grant_coins" or action == "grant_part" or action == "event_delete" or action == "tuning_reset"
	if reasonNeeded then
		local reason = text(args.reason, 120)
		if reason == nil or #string.gsub(reason, "%s", "") < 3 then
			return false, "a reason (at least 3 characters) is required"
		end
		out.reason = reason
	end
	if action == "inspect" or action == "kick" or action == "ban" or action == "unban" or action == "rollback" or action == "snapshots"
		or action == "grant_coins" or action == "remove_coins" or action == "grant_part" or action == "remove_part" or action == "trades" then
		if not userId(args.userId) then
			return false, "invalid player"
		end
		out.userId = args.userId
	end
	if action == "grant_coins" or action == "remove_coins" then
		if not isInt(args.amount, 1, cfg.Admin.MaxCoinGrant) then
			return false, string.format("amount must be a whole number from 1 to %d", cfg.Admin.MaxCoinGrant)
		end
		out.amount = args.amount
	elseif action == "grant_part" then
		if type(args.partId) ~= "string" or Parts.get(args.partId) == nil then
			return false, "unknown part"
		end
		if not isInt(args.tier or 1, 1, #cfg.Tiers) or not isInt(args.count or 1, 1, cfg.Admin.MaxPartGrant) then
			return false, string.format("tier 1-%d and count 1-%d", #cfg.Tiers, cfg.Admin.MaxPartGrant)
		end
		out.partId, out.tier, out.count = args.partId, args.tier or 1, args.count or 1
	elseif action == "remove_part" then
		if not isInt(args.uid, 1, 1e12) then
			return false, "invalid part"
		end
		out.uid = args.uid
	elseif action == "ban" then
		local seconds = args.seconds or 0
		if not isInt(seconds, 0, cfg.Admin.MaxBanSeconds) then
			return false, "invalid ban length"
		end
		out.seconds = seconds
	elseif action == "rollback" then
		if not isInt(args.index, 1, cfg.Admin.SnapshotCount) then
			return false, "invalid snapshot"
		end
		out.index = args.index
	elseif action == "announce" then
		local t = text(args.text, 160)
		if t == nil or #string.gsub(t, "%s", "") < 1 then
			return false, "write something to announce"
		end
		out.text = t
	elseif action == "event_stop" or action == "event_delete" then
		if type(args.id) ~= "string" or #args.id < 1 or #args.id > 40 then
			return false, "invalid event"
		end
		out.id = args.id
	elseif action == "event_upsert" then
		if type(args.event) ~= "table" then
			return false, "missing event"
		end
		out.event = args.event -- validated in full by Events.validate when it is saved
	elseif action == "tuning_set" then
		if type(args.key) ~= "string" or #args.key > 40 then
			return false, "invalid setting"
		end
		out.key, out.value = args.key, args.value
	elseif action == "audit" then
		out.count = if isInt(args.count or 50, 1, 200) then args.count or 50 else 50
	end
	return true, out
end

-- Data operations -------------------------------------------------------------------------------------------------------
-- All of these work on a profile that is loaded in memory (the target must be online), and report what changed.
function Admin.grantCoins(data: Profile.Data, amount: number)
	data.coins += amount
end

-- Never takes a balance below zero; returns how much was actually removed.
function Admin.removeCoins(data: Profile.Data, amount: number): number
	local taken = math.min(amount, data.coins)
	data.coins -= taken
	return taken
end

-- Gives `count` copies of a part at a tier. They roll their stats like any new part and fill the Part Index.
function Admin.grantPart(cfg: any, data: Profile.Data, partId: string, tier: number, count: number, rng: any, now: number): { number }
	local def = Parts.get(partId) :: Parts.Def
	local uids: { number } = {}
	for _ = 1, count do
		local item = Crafting.addPart(cfg, data :: any, def, rng, now)
		item.tier = tier
		Crafting.noteIndex(data :: any, partId, tier, now)
		table.insert(uids, item.uid)
	end
	return uids
end

function Admin.removePart(data: Profile.Data, uid: number): boolean
	for i, it in data.parts do
		if it.uid == uid then
			table.remove(data.parts, i)
			return true
		end
	end
	return false
end

-- A readable summary of a profile for the inspect screen: counts, not the whole inventory.
function Admin.summary(cfg: any, data: Profile.Data): { [string]: any }
	local byRarity: { [string]: number } = {}
	for _, it in data.parts do
		local def = Parts.get(it.id)
		if def then
			byRarity[def.rarity] = (byRarity[def.rarity] or 0) + 1
		end
	end
	local found = Crafting.indexProgress(data :: any)
	return {
		coins = data.coins,
		level = Profile.level(cfg.Speed, data),
		speed = math.floor(data.speed),
		rebirths = data.rebirths,
		parts = #data.parts,
		partsByRarity = byRarity,
		pets = #data.pets,
		equipped = #data.equippedPets,
		index = found,
		furniture = #data.house.items,
		passes = data.passes,
		bagUpgrades = data.bagUpgrades,
		trades = #data.tradeJournal.applied,
		pendingTrades = #data.tradeJournal.pending,
	}
end

-- Snapshots and rollback --------------------------------------------------------------------------------------------------
export type Snapshot = { t: number, data: any }

-- Adds a snapshot (newest last), keeping only the most recent `max`. A snapshot taken within `minGap` seconds of the
-- last one replaces it instead of adding another, so a burst of saves cannot push the useful old ones out.
function Admin.pushSnapshot(list: any, snap: Snapshot, max: number, minGap: number): { Snapshot }
	local out: { Snapshot } = {}
	if type(list) == "table" then
		for _, s in list do
			if type(s) == "table" and type(s.t) == "number" and type(s.data) == "table" then
				table.insert(out, s)
			end
		end
	end
	local last = out[#out]
	if last and snap.t - last.t < minGap then
		out[#out] = snap
	else
		table.insert(out, snap)
	end
	while #out > max do
		table.remove(out, 1)
	end
	return out
end

-- Restores a snapshot into the live profile, in place (other code holds this table). The snapshot is loaded through
-- Profile.load first, so even a damaged snapshot cannot put invalid data back. Returns false if there is none.
function Admin.rollback(cfg: any, data: Profile.Data, snapshotData: any): boolean
	if type(snapshotData) ~= "table" then
		return false
	end
	local restored = Profile.load(snapshotData, cfg)
	-- Some things must survive a rollback. The trade journal (a pending trade must still be recoverable and applied ids
	-- must not be forgotten), the receipts of Robux purchases (so nothing is granted twice), and passes (owned on
	-- Roblox for good). Ids never go backwards, so an old id is never reused. Anything else bought or earned after the
	-- snapshot is undone: the audit log shows what that was, for a manual re-grant.
	restored.tradeJournal = data.tradeJournal
	restored.receipts = data.receipts
	restored.nextUid = math.max(restored.nextUid, data.nextUid)
	for key, owned in data.passes do
		if owned then
			restored.passes[key] = true
		end
	end
	local anyData: any = data
	for k in anyData do
		anyData[k] = nil
	end
	for k, v in restored :: any do
		anyData[k] = v
	end
	return true
end

return Admin
