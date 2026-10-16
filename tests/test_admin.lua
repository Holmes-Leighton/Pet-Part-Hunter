--!strict
local Test = require("./harness")
local Admin = require("../src/Shared/Admin")
local AuditLog = require("../src/Shared/AuditLog")
local Bans = require("../src/Shared/Bans")
local Profile = require("../src/Shared/Profile")
local Rng = require("../src/Shared/Rng")
local Tuning = require("../src/Shared/Tuning")
local Config = require("../src/Shared/Config")

local function cfgWith(owners: { number }, admins: { number }, mods: { number }, groupId: number?): any
	local cfg: any = table.clone(Config)
	cfg.Admin = table.clone(Config.Admin)
	cfg.Admin.Owners, cfg.Admin.Admins, cfg.Admin.Mods = owners, admins, mods
	cfg.Admin.GroupId = groupId or 0
	return cfg
end

local function fresh(): Profile.Data
	return Profile.load(nil, Config)
end

Test.case("nobody is an admin by default", function()
	Test.eq(Admin.roleFor(Config, 12345, nil), "none")
	Test.eq(Admin.roleFor(Config, 12345, 255), "none", "a group rank counts for nothing when no group is set")
end)

Test.case("roles come from the listed ids, the highest one wins", function()
	local cfg = cfgWith({ 1 }, { 2, 1 }, { 3, 2, 1 })
	Test.eq(Admin.roleFor(cfg, 1, nil), "owner")
	Test.eq(Admin.roleFor(cfg, 2, nil), "admin")
	Test.eq(Admin.roleFor(cfg, 3, nil), "mod")
	Test.eq(Admin.roleFor(cfg, 4, nil), "none")
end)

Test.case("roles can come from a group rank", function()
	local cfg = cfgWith({}, {}, {}, 777)
	Test.eq(Admin.roleFor(cfg, 9, 0), "none")
	Test.eq(Admin.roleFor(cfg, 9, 99), "none")
	Test.eq(Admin.roleFor(cfg, 9, 100), "mod")
	Test.eq(Admin.roleFor(cfg, 9, 200), "admin")
	Test.eq(Admin.roleFor(cfg, 9, 255), "owner")
	Test.eq(Admin.roleFor(cfg, 9, nil), "none")
	local both = cfgWith({}, { 9 }, {}, 777)
	Test.eq(Admin.roleFor(both, 9, 100), "admin", "the list outranks a low group rank")
end)

Test.case("commands need the right role; unknown commands are never allowed", function()
	Test.truthy(Admin.can("mod", "kick") and Admin.can("mod", "announce") and Admin.can("mod", "inspect"))
	Test.truthy(not Admin.can("mod", "ban") and not Admin.can("mod", "grant_coins") and not Admin.can("mod", "rollback"))
	Test.truthy(Admin.can("admin", "ban") and Admin.can("admin", "event_upsert") and Admin.can("admin", "tuning_set"))
	Test.truthy(not Admin.can("admin", "event_delete") and not Admin.can("admin", "tuning_reset"))
	Test.truthy(Admin.can("owner", "event_delete") and Admin.can("owner", "kick"))
	Test.truthy(not Admin.can("none", "players") and not Admin.can("none", "kick"))
	Test.truthy(not Admin.can("owner", "delete_everything"))
	Test.truthy(not Admin.can("owner", "__index"))
end)

Test.case("every command in the table has a role that exists", function()
	for action, role in Admin.ACTIONS do
		Test.truthy(role == "mod" or role == "admin" or role == "owner", action)
	end
end)

Test.case("destructive commands need a written reason", function()
	for _, action in { "kick", "ban", "remove_coins", "remove_part", "rollback", "grant_coins", "grant_part" } do
		local ok, why = Admin.validate(Config, action, { userId = 5, amount = 10, partId = "Chicken_Head", uid = 3, index = 1 })
		Test.eq(ok, false, action)
		Test.eq(why, "a reason (at least 3 characters) is required", action)
	end
	Test.eq((Admin.validate(Config, "kick", { userId = 5, reason = "  " })), false)
	Test.eq((Admin.validate(Config, "kick", { userId = 5, reason = "ab" })), false)
	Test.eq((Admin.validate(Config, "kick", { userId = 5, reason = "spamming chat" })), true)
end)

Test.case("arguments are strictly checked: players, amounts, parts, tiers, lengths", function()
	local function v(action: string, args: any): boolean
		return (Admin.validate(Config, action, args))
	end
	local r = "testing it"
	Test.eq(v("grant_coins", { userId = 5, amount = 100, reason = r }), true)
	Test.eq(v("grant_coins", { userId = 5, amount = 0, reason = r }), false)
	Test.eq(v("grant_coins", { userId = 5, amount = -5, reason = r }), false)
	Test.eq(v("grant_coins", { userId = 5, amount = 1.5, reason = r }), false)
	Test.eq(v("grant_coins", { userId = 5, amount = Config.Admin.MaxCoinGrant + 1, reason = r }), false)
	Test.eq(v("grant_coins", { userId = 5, amount = 0 / 0, reason = r }), false)
	Test.eq(v("grant_coins", { userId = "5", amount = 10, reason = r }), false)
	Test.eq(v("grant_coins", { userId = -1, amount = 10, reason = r }), false)
	Test.eq(v("grant_coins", { amount = 10, reason = r }), false)
	Test.eq(v("grant_part", { userId = 5, partId = "Chicken_Head", reason = r }), true, "tier and count default")
	Test.eq(v("grant_part", { userId = 5, partId = "Dragon_Head", reason = r }), false)
	Test.eq(v("grant_part", { userId = 5, partId = "Chicken_Head", tier = 9, reason = r }), false)
	Test.eq(v("grant_part", { userId = 5, partId = "Chicken_Head", count = Config.Admin.MaxPartGrant + 1, reason = r }), false)
	Test.eq(v("ban", { userId = 5, seconds = 3600, reason = r }), true)
	Test.eq(v("ban", { userId = 5, reason = r }), true, "no length means permanent")
	Test.eq(v("ban", { userId = 5, seconds = -1, reason = r }), false)
	Test.eq(v("ban", { userId = 5, seconds = Config.Admin.MaxBanSeconds + 1, reason = r }), false)
	Test.eq(v("rollback", { userId = 5, index = 0, reason = r }), false)
	Test.eq(v("rollback", { userId = 5, index = Config.Admin.SnapshotCount + 1, reason = r }), false)
	Test.eq(v("announce", { text = "Hello" }), true)
	Test.eq(v("announce", { text = "   " }), false)
	Test.eq(v("announce", {}), false)
	Test.eq(v("inspect", { userId = 5 }), true)
	Test.eq(v("inspect", {}), false)
	Test.eq(v("event_stop", { id = "x" }), true)
	Test.eq(v("event_stop", { id = string.rep("x", 41) }), false)
	Test.eq(v("event_upsert", {}), false)
	Test.eq(v("event_upsert", { event = {} }), true)
	Test.eq(v("nothing", {}), false)
	Test.eq(v("kick", nil), false, "no arguments at all")
end)

Test.case("text is cleaned: control characters removed, length capped", function()
	local ok, args = Admin.validate(Config, "announce", { text = "line1\nline2\0" .. string.rep("x", 400) })
	Test.eq(ok, true)
	Test.truthy(#args.text <= 160)
	Test.truthy(string.find(args.text, "\n", 1, true) == nil)
	local ok2, args2 = Admin.validate(Config, "kick", { userId = 5, reason = "bad\r\nthing", extra = "ignored" })
	Test.eq(ok2, true)
	Test.eq(args2.extra, nil, "unknown fields are dropped")
	Test.truthy(string.find(args2.reason, "\n", 1, true) == nil)
end)

Test.case("grant and remove coins; removing never goes below zero", function()
	local d = fresh()
	Admin.grantCoins(d, 500)
	Test.eq(d.coins, 500)
	Test.eq(Admin.removeCoins(d, 200), 200)
	Test.eq(d.coins, 300)
	Test.eq(Admin.removeCoins(d, 9999), 300, "only what they have")
	Test.eq(d.coins, 0)
end)

Test.case("granting parts: right tier and count, unique ids, Part Index filled, saves cleanly", function()
	local d = fresh()
	local uids = Admin.grantPart(Config, d, "Kraken_Head", 3, 4, Rng.new(1), 1000)
	Test.eq(#uids, 4)
	Test.eq(#d.parts, 4)
	for _, it in d.parts do
		Test.eq(it.tier, 3)
		Test.eq(it.id, "Kraken_Head")
	end
	Test.eq(d.index.Kraken_Head.best, 3)
	Test.eq(Profile.load(d, Config), d)
	Test.truthy(Admin.removePart(d, uids[2]))
	Test.eq(#d.parts, 3)
	Test.eq(Admin.removePart(d, uids[2]), false, "already gone")
end)

Test.case("the inspect summary counts things without dumping the inventory", function()
	local d = fresh()
	d.coins = 42
	Admin.grantPart(Config, d, "Chicken_Head", 1, 2, Rng.new(1), 1)
	Admin.grantPart(Config, d, "Kraken_Head", 1, 1, Rng.new(2), 1)
	local s = Admin.summary(Config, d)
	Test.eq(s.coins, 42)
	Test.eq(s.parts, 3)
	Test.eq(s.partsByRarity, { Common = 2, Mythic = 1 })
	Test.eq(s.rebirths, 0)
end)

Test.case("snapshots keep the newest few, and a burst of saves does not push good ones out", function()
	local list: any = nil
	for i = 1, 10 do
		list = Admin.pushSnapshot(list, { t = i * 1000, data = { n = i } }, 6, 300)
	end
	Test.eq(#list, 6)
	Test.eq(list[1].data.n, 5)
	Test.eq(list[6].data.n, 10)
	-- Two snapshots within the gap: the newer replaces the older.
	local burst = Admin.pushSnapshot(list, { t = 10000 + 60, data = { n = 99 } }, 6, 300)
	Test.eq(#burst, 6)
	Test.eq(burst[6].data.n, 99)
	Test.eq(burst[5].data.n, 9, "older snapshots are kept")
	Test.eq(#Admin.pushSnapshot({ "junk", { t = "x" } }, { t = 1, data = {} }, 6, 300), 1, "a damaged list is repaired")
end)

Test.case("rollback restores an earlier state in place and keeps what must survive", function()
	local d = fresh()
	d.coins = 100
	Admin.grantPart(Config, d, "Chicken_Head", 1, 2, Rng.new(1), 1)
	local snapshot = Profile.load(d, Config) -- what was saved earlier
	-- Later: more coins, an item stolen by an exploit, a Robux receipt, a pass, an applied trade, a pending trade.
	d.coins = 9999999
	Admin.grantPart(Config, d, "Kraken_Head", 3, 5, Rng.new(2), 2)
	d.receipts = { "receipt-1" }
	d.passes.DoubleCoins = true
	d.tradeJournal.applied = { "trade-7" }
	d.tradeJournal.pending = { { id = "trade-8", key = "k" } }
	local liveNextUid = d.nextUid
	local journal = d.tradeJournal
	local same = d
	Test.eq(Admin.rollback(Config, d, snapshot), true)
	Test.truthy(d == same, "restored in place, so other code holding the profile sees it")
	Test.eq(d.coins, 100)
	Test.eq(#d.parts, 2, "the exploited parts are gone")
	Test.eq(d.index.Kraken_Head, nil)
	Test.eq(d.receipts, { "receipt-1" }, "purchase receipts survive")
	Test.truthy(d.passes.DoubleCoins, "passes survive")
	Test.truthy(d.tradeJournal == journal and d.tradeJournal.applied[1] == "trade-7" and #d.tradeJournal.pending == 1, "the trade journal survives")
	Test.truthy(d.nextUid >= liveNextUid, "ids never go backwards")
	Test.eq(Profile.load(d, Config), d, "the result is a valid profile")
	Test.eq(Admin.rollback(Config, d, nil), false)
	Test.eq(Admin.rollback(Config, d, "junk"), false)
end)

Test.case("a damaged snapshot cannot put invalid data back", function()
	local d = fresh()
	local bad = { coins = -5, parts = { { uid = 1, id = "Fake_Head", tier = 1, stats = {} } }, rebirths = 999 }
	Test.eq(Admin.rollback(Config, d, bad), true)
	Test.eq(d.coins, 0)
	Test.eq(#d.parts, 0)
	Test.eq(d.rebirths, Config.Speed.MaxRebirths)
	Test.eq(Profile.load(d, Config), d)
end)

-- Audit log ------------------------------------------------------------------------------------------------------------
Test.case("an audit entry records who, what, target, when and the outcome", function()
	local e = AuditLog.entry(1700000000, 11, "Boss", "admin", "grant_coins", 22, { amount = 500, reason = "compensation" }, true, "granted 500", "job-1")
	Test.eq(e.admin, 11)
	Test.eq(e.action, "grant_coins")
	Test.eq(e.target, 22)
	Test.eq(e.t, 1700000000)
	Test.eq(e.args.amount, 500)
	Test.eq(e.ok, true)
	Test.truthy(string.find(AuditLog.summary(e), "grant_coins on 22 -> ok", 1, true) ~= nil)
	local denied = AuditLog.entry(1, 5, "Sneaky", "none", "ban", 9, {}, false, "not allowed", "j")
	Test.truthy(string.find(AuditLog.summary(denied), "DENIED", 1, true) ~= nil)
end)

Test.case("audit entries are scrubbed: finite numbers, short strings, no functions or deep tables", function()
	local e = AuditLog.entry(1, 1, string.rep("n", 100), "mod", "kick", nil, {
		bad = 0 / 0,
		inf = math.huge,
		long = string.rep("x", 1000),
		fn = function() end,
		deep = { a = { b = { c = { d = 1 } } } },
	}, true, string.rep("r", 1000), "j")
	Test.eq(e.args.bad, 0)
	Test.eq(e.args.inf, 0)
	Test.eq(#e.args.long, 200)
	Test.eq(e.args.fn, nil)
	Test.eq(e.args.deep.a.b, nil, "nesting is capped")
	Test.eq(#e.name, 40)
	Test.eq(#e.result, 200)
end)

Test.case("the audit day key is the UTC date; lists are capped, newest kept", function()
	Test.eq(AuditLog.dayKey(1700000000), "A20231114")
	local list: any = nil
	for i = 1, 8 do
		list = AuditLog.append(list, AuditLog.entry(i, 1, "a", "mod", "kick", nil, { n = i }, true, "ok", "j"), 5)
	end
	Test.eq(#list, 5)
	Test.eq(list[1].args.n, 4)
	Test.eq(list[5].args.n, 8)
	Test.eq(#AuditLog.append({ "junk" }, AuditLog.entry(1, 1, "a", "mod", "kick", nil, {}, true, "ok", "j"), 5), 1)
end)

-- Bans -------------------------------------------------------------------------------------------------------------------
Test.case("bans: timed ones expire, permanent ones do not, junk records never ban", function()
	local timed = Bans.new(5, 3600, "cheating", 1, 1000)
	Test.eq(timed.untilTime, 4600)
	Test.truthy(Bans.isActive(timed, 4599))
	Test.truthy(not Bans.isActive(timed, 4600))
	local perm = Bans.new(5, 0, "exploiting", 1, 1000)
	Test.truthy(Bans.isActive(perm, 1e12))
	Test.truthy(not Bans.isActive(nil, 1))
	Test.truthy(not Bans.isActive("banned", 1))
	Test.truthy(not Bans.isActive({ untilTime = "x" }, 1))
	Test.truthy(string.find(Bans.message(perm, 5), "permanently", 1, true) ~= nil)
	Test.truthy(string.find(Bans.message(timed, 1000), "60 minute", 1, true) ~= nil)
	Test.eq(#Bans.new(5, 0, string.rep("x", 500), 1, 1).reason, 120)
end)

-- Tuning ------------------------------------------------------------------------------------------------------------------
Test.case("tuning: only real settings, in range; defaults are not stored", function()
	local v = Tuning.new()
	Test.eq({ Tuning.set(Config, v, "chaserMult", 1.5) }, { true, "ok" })
	Test.eq(Tuning.get(Config, v, "chaserMult"), 1.5)
	Test.eq(Tuning.get(Config, v, "respawnMult"), 1)
	Test.eq(Tuning.set(Config, v, "chaserMult", 1), "ok" == "ok" and true, "setting the default is accepted")
	Test.eq(v.chaserMult, nil, "and removes the stored value")
	Test.eq(select(2, Tuning.set(Config, v, "chaserMult", 0)), "chaserMult must be between 0.2 and 3")
	Test.eq(select(2, Tuning.set(Config, v, "chaserMult", 50)), "chaserMult must be between 0.2 and 3")
	Test.eq((Tuning.set(Config, v, "chaserMult", 0 / 0)), false)
	Test.eq((Tuning.set(Config, v, "chaserMult", "fast")), false)
	Test.eq(select(2, Tuning.set(Config, v, "godMode", true)), "unknown setting")
	Test.eq(select(2, Tuning.set(Config, v, "area.Atlantis.chaser", 1.2)), "unknown setting")
	Test.eq(select(2, Tuning.set(Config, v, "area.Mythic.speed", 1.2)), "unknown setting")
	Test.eq(select(2, Tuning.set(Config, v, 5, 1)), "unknown setting")
	Test.eq(select(2, Tuning.set(Config, v, "tradingEnabled", "no")), "tradingEnabled is on or off")
end)

Test.case("area tuning: a per-area chaser multiplier on top of the global one, and closing an area", function()
	local v = Tuning.new()
	Test.near(Tuning.chaserMult(Config, v, "Rare"), 1)
	Tuning.set(Config, v, "chaserMult", 1.5)
	Tuning.set(Config, v, "area.Rare.chaser", 0.8)
	Test.near(Tuning.chaserMult(Config, v, "Rare"), 1.2)
	Test.near(Tuning.chaserMult(Config, v, "Mythic"), 1.5)
	Test.truthy(Tuning.areaOpen(Config, v, "Mythic"))
	Tuning.set(Config, v, "area.Mythic.open", false)
	Test.truthy(not Tuning.areaOpen(Config, v, "Mythic"))
	Test.truthy(Tuning.areaOpen(Config, v, "Rare"))
	Tuning.set(Config, v, "tradingEnabled", false)
	Test.eq(Tuning.get(Config, v, "tradingEnabled"), false)
	Test.eq(Tuning.chaserMult(Config, v, "NoSuchArea"), 1.5, "an unknown area has no area setting")
end)

Test.case("a stored tuning table is sanitised on load", function()
	local clean = Tuning.sanitize(Config, { chaserMult = 99, respawnMult = 2, tradingEnabled = false, junk = 1, ["area.Mythic.open"] = false, ["area.Nope.open"] = false })
	Test.eq(clean, { respawnMult = 2, tradingEnabled = false, ["area.Mythic.open"] = false })
	Test.eq(Tuning.sanitize(Config, "garbage"), {})
	Test.eq(Tuning.sanitize(Config, nil), {})
end)

Test.case("the tuning list shows every setting with its default", function()
	local list = Tuning.list(Config, Tuning.new())
	Test.eq(#list, 3 + #Config.Areas * 2)
	Test.eq(list[1], { key = "chaserMult", value = 1, default = 1, kind = "number" })
	local seen: { [string]: boolean } = {}
	for _, item in list do
		Test.truthy(not seen[item.key], "unique")
		seen[item.key] = true
	end
	Test.truthy(seen["area.Mythic.open"] and seen["area.Common.chaser"])
end)

Test.done()
