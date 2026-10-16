--!strict
local Test = require("./harness")
local ExploitCheck = require("../src/Shared/ExploitCheck")
local Metrics = require("../src/Shared/Metrics")
local Profile = require("../src/Shared/Profile")
local Crafting = require("../src/Shared/Crafting")
local Parts = require("../src/Shared/Parts")
local Rng = require("../src/Shared/Rng")
local Admin = require("../src/Shared/Admin")
local Config = require("../src/Shared/Config")

-- Metrics ------------------------------------------------------------------------------------------------------------------
Test.case("events are counted and summed, with a split by area, source, sink and so on", function()
	local m = Metrics.new(0)
	Metrics.record(m, "RunEscaped", 3, { area = "Rare" })
	Metrics.record(m, "RunEscaped", 2, { area = "Rare" })
	Metrics.record(m, "RunEscaped", 1, { area = "Common" })
	Metrics.record(m, "CoinsEarned", 500, { source = "SellParts" })
	Metrics.record(m, "Rebirth")
	local s = Metrics.snapshot(m, 60)
	Test.eq(s.events["RunEscaped"], { n = 3, sum = 6 })
	Test.eq(s.events["RunEscaped|area=Rare"], { n = 2, sum = 5 })
	Test.eq(s.events["RunEscaped|area=Common"], { n = 1, sum = 1 })
	Test.eq(s.events["CoinsEarned|source=SellParts"], { n = 1, sum = 500 })
	Test.eq(s.events["Rebirth"], { n = 1, sum = 1 }, "no value counts as 1")
	Test.eq(s.seconds, 60)
end)

Test.case("a snapshot starts a fresh interval", function()
	local m = Metrics.new(0)
	Metrics.record(m, "X", 1)
	Metrics.snapshot(m, 60)
	local second = Metrics.snapshot(m, 120)
	Test.eq(second.events, {})
	Test.eq(second.seconds, 60)
end)

Test.case("free text never becomes a metric key, and nasty numbers are made safe", function()
	local m = Metrics.new(0)
	Metrics.record(m, "ProductPurchased", 1, { product = "LuckBoost", note = "anything the player typed" })
	Metrics.record(m, "Odd", 0 / 0)
	Metrics.record(m, "Odd", math.huge)
	local s = Metrics.snapshot(m, 10)
	Test.eq(s.events["ProductPurchased|product=LuckBoost"].n, 1)
	for key in s.events do
		Test.truthy(not string.find(key, "player typed", 1, true), key)
	end
	Test.eq(s.events["Odd"].sum, 0)
	local long = Metrics.new(0)
	Metrics.record(long, "E", 1, { area = string.rep("a", 200) })
	for key in Metrics.snapshot(long, 1).events do
		Test.truthy(#key < 60, "long values are cut")
	end
end)

Test.case("the number of metric keys is capped, so a bug cannot grow memory without limit", function()
	local m = Metrics.new(0)
	for i = 1, 2000 do
		Metrics.record(m, "Event" .. i, 1)
	end
	local count = 0
	for _ in Metrics.snapshot(m, 1).events do
		count += 1
	end
	Test.eq(count, 400)
end)

Test.case("rollups add snapshots together; rates are per hour", function()
	local a = Metrics.new(0)
	Metrics.record(a, "CoinsEarned", 1000)
	local s1 = Metrics.snapshot(a, 60)
	Metrics.record(a, "CoinsEarned", 500)
	Metrics.record(a, "CoinsSpent", 200)
	local s2 = Metrics.snapshot(a, 120)
	local hour = Metrics.rollup({ s1, s2 })
	Test.eq(hour.seconds, 120)
	Test.eq(hour.events.CoinsEarned.sum, 1500)
	Test.near(Metrics.perHour(hour, "CoinsEarned", true), 1500 * 3600 / 120)
	Test.eq(Metrics.perHour(hour, "Nothing"), 0)
	Test.eq(Metrics.coinBalance(hour), 1300, "earned minus spent: the inflation signal")
end)

Test.case("catch rate per area: caught over finished runs, nothing when there were none", function()
	local m = Metrics.new(0)
	for _ = 1, 3 do
		Metrics.record(m, "RunCaught", 2, { area = "Mythic" })
	end
	Metrics.record(m, "RunEscaped", 3, { area = "Mythic" })
	Metrics.record(m, "RunEscaped", 1, { area = "Common" })
	local s = Metrics.snapshot(m, 100)
	Test.near(Metrics.catchRate(s, "Mythic") :: number, 0.75)
	Test.near(Metrics.catchRate(s, "Common") :: number, 0)
	Test.eq(Metrics.catchRate(s, "Rare"), nil)
end)

-- Exploit checks ----------------------------------------------------------------------------------------------------------
Test.case("speed: normal running passes, a speed hack is caught, with tolerance for jumps", function()
	-- WalkSpeed 30: allowed = 30 * 1.5 + 8 = 53 studs/s.
	Test.eq(ExploitCheck.speedViolation(Config, 30, 15, 0.5), false, "30 studs/s")
	Test.eq(ExploitCheck.speedViolation(Config, 30, 26, 0.5), false, "52 studs/s is inside the tolerance")
	Test.eq(ExploitCheck.speedViolation(Config, 30, 40, 0.5), true, "80 studs/s")
	Test.eq(ExploitCheck.speedViolation(Config, 12, 20, 0.5), true, "a new player at 40 studs/s")
	Test.eq(ExploitCheck.speedViolation(Config, 12, 5, 0), false, "no time passed, no judgement")
end)

Test.case("teleports: a short hop is fine, a huge jump is not", function()
	Test.eq(ExploitCheck.teleportViolation(Config, 30, 20, 0.5), false)
	Test.eq(ExploitCheck.teleportViolation(Config, 30, 39, 0.5), false, "under the minimum distance")
	Test.eq(ExploitCheck.teleportViolation(Config, 12, 200, 0.5), true)
	Test.eq(ExploitCheck.teleportViolation(Config, 60, 150, 1), false, "a fast player over a full second")
	Test.eq(ExploitCheck.teleportViolation(Config, 60, 400, 1), true)
	Test.eq(ExploitCheck.teleportViolation(Config, 12, 500, 0), false)
end)

Test.case("hauls: more than the bag holds is impossible; a very large haul is suspicious", function()
	Test.eq(ExploitCheck.haulViolation(Config, 3, 3), nil)
	Test.eq(ExploitCheck.haulViolation(Config, 4, 3), "over_capacity")
	Test.eq(ExploitCheck.haulViolation(Config, 14, 40), nil, "a big bag filled legitimately")
	Test.eq(ExploitCheck.haulViolation(Config, Config.Exploit.HugeHaul, 40), "huge_haul")
	Test.eq(ExploitCheck.haulViolation(Config, 20, 10), "over_capacity", "over capacity is checked first")
end)

Test.case("duplicate ids are found across parts, pets and the parts inside pets", function()
	local d = Profile.load(nil, Config)
	d.coins = 1000
	local a = Crafting.addPart(Config, d, Parts.get("Chicken_Head") :: Parts.Def, Rng.new(1), 1)
	Crafting.addPart(Config, d, Parts.get("Tiger_Legs") :: Parts.Def, Rng.new(2), 1)
	Test.eq(ExploitCheck.duplicateUids(d), {})
	table.insert(d.parts, { uid = a.uid, id = "Fox_Tail", tier = 1, stats = a.stats }) -- a duplicated id
	Test.eq(ExploitCheck.duplicateUids(d), { a.uid })
	table.remove(d.parts)
	local pet = Crafting.buildPet(Config, d, { Head = a.uid }) :: Crafting.Pet
	Test.eq(ExploitCheck.duplicateUids(d), {})
	table.insert(d.parts, { uid = pet.slots.Head.uid, id = "Owl_Body", tier = 1, stats = a.stats }) -- same id as a part inside the pet
	Test.eq(ExploitCheck.duplicateUids(d), { pet.slots.Head.uid })
end)

Test.case("a normal profile after real play has no duplicates", function()
	local d = Profile.load(nil, Config)
	d.coins = 100000
	local rng = Rng.new(5)
	for i = 1, 30 do
		Crafting.addPart(Config, d, Parts.get(if i % 2 == 0 then "Chicken_Head" else "Tiger_Legs") :: Parts.Def, rng, i)
	end
	Crafting.merge(Config, d, "Chicken_Head", 1, 99)
	Test.eq(ExploitCheck.duplicateUids(d), {})
end)

Test.case("strikes count repeats in a window, per player and kind, and can be cleared", function()
	local s: ExploitCheck.Strikes = {}
	Test.eq(ExploitCheck.strike(s, 1, "speed", 0, 60), 1)
	Test.eq(ExploitCheck.strike(s, 1, "speed", 10, 60), 2)
	Test.eq(ExploitCheck.strike(s, 1, "teleport", 10, 60), 1, "kinds are separate")
	Test.eq(ExploitCheck.strike(s, 2, "speed", 10, 60), 1, "players are separate")
	Test.eq(ExploitCheck.strike(s, 1, "speed", 100, 60), 1, "old strikes fall out of the window")
	ExploitCheck.clearStrikes(s, 1)
	Test.eq(ExploitCheck.strike(s, 1, "speed", 101, 60), 1)
	Test.eq(ExploitCheck.strike(s, 2, "speed", 70, 60), 2, "other players are untouched by the clear")
end)

Test.case("exploit log entries: capped text, severity range, a list per UTC day", function()
	local e = ExploitCheck.entry(1700000000, 9, string.rep("n", 99), "speed", string.rep("d", 999), 7, "job")
	Test.eq(#e.name, 40)
	Test.eq(#e.detail, 200)
	Test.eq(e.severity, 3)
	Test.eq(ExploitCheck.entry(1, 1, "a", "speed", "x", 0, "j").severity, 1)
	Test.eq(ExploitCheck.dayKey(1700000000), "X20231114")
	local list: any = nil
	for i = 1, 8 do
		list = ExploitCheck.append(list, ExploitCheck.entry(i, 1, "a", "speed", "n" .. i, 1, "j"), 5)
	end
	Test.eq(#list, 5)
	Test.eq(list[1].detail, "n4")
	Test.truthy(string.find(ExploitCheck.summary(e), "speed severity 3", 1, true) ~= nil)
	Test.eq(#ExploitCheck.append("junk", e, 5), 1)
end)

Test.case("mods can read metrics and the exploit log, but not change anything", function()
	Test.truthy(Admin.can("mod", "metrics") and Admin.can("mod", "exploits"))
	Test.truthy(not Admin.can("none", "metrics"))
	Test.eq((Admin.validate(Config, "metrics", {})), true)
	Test.eq((Admin.validate(Config, "exploits", {})), true)
end)

Test.done()
