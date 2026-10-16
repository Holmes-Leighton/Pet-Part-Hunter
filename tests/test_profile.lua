--!strict
local Test = require("./harness")
local Speed = require("../src/Shared/Speed")
local Profile = require("../src/Shared/Profile")
local RateLimiter = require("../src/Shared/RateLimiter")
local Config = require("../src/Shared/Config")
local Crafting = require("../src/Shared/Crafting")
local Parts = require("../src/Shared/Parts")
local Rng = require("../src/Shared/Rng")

local S = Config.Speed

local function fresh(): Profile.Data
	return Profile.load(nil, Config)
end

Test.case("a missing or non-table save loads the defaults", function()
	Test.eq(fresh(), Profile.default(Config.Data.SchemaVersion))
	Test.eq(Profile.load("garbage", Config), Profile.default(Config.Data.SchemaVersion))
end)

Test.case("bad fields are repaired and speed is clamped to the level cap", function()
	local d = Profile.load({ coins = -5, speed = 0 / 0, rebirths = 999, padTier = 99, passes = { DoubleSpeed = true, x = 1, [3] = true } }, Config)
	Test.eq(d.coins, 0)
	Test.eq(d.speed, 0)
	Test.eq(d.rebirths, S.MaxRebirths)
	Test.eq(d.padTier, #Config.Pads)
	Test.eq(d.passes, { DoubleSpeed = true })
	local huge = Profile.load({ speed = 1e300, rebirths = 0 }, Config)
	Test.near(huge.speed, Speed.totalCap(S, 0), 1e-6)
end)

Test.case("good saves round-trip", function()
	local d = fresh()
	d.coins, d.speed, d.rebirths, d.padTier = 123, 500, 1, 3
	Crafting.addPart(Config, d, Parts.get("Chicken_Head") :: Parts.Def, Rng.new(1), 100)
	Crafting.addPart(Config, d, Parts.get("Tiger_Legs") :: Parts.Def, Rng.new(2), 100)
	local pet = Crafting.buildPet(Config, d, { Head = d.parts[1].uid })
	Test.truthy(pet, "built a pet")
	Test.truthy(Crafting.equip(d, (pet :: Crafting.Pet).uid))
	Test.eq(Profile.load(d, Config), d)
end)

Test.case("addSpeed applies the rebirth multiplier and the 2x pass", function()
	local d = fresh()
	Test.near(Profile.addSpeed(S, d, 10), 10)
	d.rebirths = 1
	Test.near(Profile.addSpeed(S, d, 10), 15)
	d.passes.DoubleSpeed = true
	Test.near(Profile.addSpeed(S, d, 10), 30)
	Test.eq(Profile.addSpeed(S, d, -5), 0)
end)

Test.case("the 2x pass doubles Speed gained but not the WalkSpeed cap", function()
	local d = fresh()
	d.passes.DoubleSpeed = true
	d.speed = Speed.totalCap(S, 0)
	Test.truthy(Profile.walkSpeed(S, d) <= S.WalkCap)
	Test.eq(Profile.addSpeed(S, d, 1000), 0, "stopped at the level cap")
end)

Test.case("speed stops at the level cap until the player rebirths", function()
	local d = fresh()
	Profile.addSpeed(S, d, 1e9)
	Test.eq(Profile.level(S, d), Speed.levelCap(S, 0))
	Test.truthy(Speed.canRebirth(S, d.speed, d.rebirths))
end)

Test.case("rebirth resets Speed, keeps coins/pets/parts/pads, and needs the level", function()
	local d = fresh()
	d.coins, d.padTier = 77, 3
	Crafting.addPart(Config, d, Parts.get("Fox_Tail") :: Parts.Def, Rng.new(3), 1)
	d.pets = { { uid = 99, slots = { Tail = d.parts[1] } } }
	d.speed = Speed.totalForLevel(S, 14)
	Test.truthy(not Profile.rebirth(S, d), "level 14 is not enough")
	Test.eq(d.rebirths, 0)
	Profile.addSpeed(S, d, 1e9)
	Test.truthy(Profile.rebirth(S, d))
	Test.eq(d.rebirths, 1)
	Test.eq(d.speed, 0)
	Test.eq(Profile.level(S, d), 1)
	Test.eq(d.coins, 77)
	Test.eq(d.padTier, 3)
	Test.eq(#d.parts, 1)
	Test.eq(#d.pets, 1)
	Test.truthy(not Profile.rebirth(S, d), "cannot rebirth again straight away")
end)

Test.case("rebirth raises how far the player can train and how fast", function()
	local d = fresh()
	Profile.addSpeed(S, d, 1e12)
	Profile.rebirth(S, d)
	Profile.addSpeed(S, d, 1e12)
	Test.eq(Profile.level(S, d), Speed.levelCap(S, 1))
	Test.truthy(Profile.walkSpeed(S, d) > Speed.walkSpeed(S, Speed.levelCap(S, 0)), "faster than at Rebirth 0")
end)

Test.case("pad purchase: in order, needs coins and rebirths, spends coins", function()
	local d = fresh()
	local P = Config.Pads
	Test.eq({ Profile.buyPad(P, d, 3) }, { false, "buy the previous pad first" })
	Test.eq({ Profile.buyPad(P, d, 1) }, { false, "already owned" })
	Test.eq({ Profile.buyPad(P, d, 2) }, { false, "not enough coins" })
	d.coins = 600
	Test.eq({ Profile.buyPad(P, d, 2) }, { true, "ok" })
	Test.eq(d.coins, 100)
	Test.eq(d.padTier, 2)
	d.padTier, d.coins = 4, 1e9
	Test.eq({ Profile.buyPad(P, d, 5) }, { false, "needs rebirth 1" })
	d.rebirths = 1
	Test.eq({ Profile.buyPad(P, d, 5) }, { true, "ok" })
	Test.eq({ Profile.buyPad(P, d, 7) }, { false, "no such pad" })
end)

Test.case("pad rate only for owned tiers; rates match the spec table", function()
	local d = fresh()
	Test.eq(Profile.padRate(Config.Pads, d, 1), 1)
	Test.eq(Profile.padRate(Config.Pads, d, 2), nil)
	local rates = {}
	for _, p in Config.Pads do
		table.insert(rates, p.rate)
	end
	Test.eq(rates, { 1, 25, 50, 100, 250, 500 })
end)

Test.case("session lock: free, own, fresh-foreign (refused) and stale-foreign (taken over)", function()
	Test.truthy(Profile.canAcquire(nil, "A", 100, 120))
	Test.truthy(Profile.canAcquire({ jobId = "A", time = 99 }, "A", 100, 120))
	Test.truthy(not Profile.canAcquire({ jobId = "B", time = 99 }, "A", 100, 120))
	Test.truthy(Profile.canAcquire({ jobId = "B", time = 100 }, "A", 300, 120))
end)

Test.case("rate limiter allows a burst, then the refill rate, per key", function()
	local rl = RateLimiter.new(1, 2)
	Test.truthy(rl:allow("a", 0))
	Test.truthy(rl:allow("a", 0))
	Test.truthy(not rl:allow("a", 0), "burst used up")
	Test.truthy(rl:allow("b", 0), "other keys unaffected")
	Test.truthy(not rl:allow("a", 0.5), "half a token is not enough")
	Test.truthy(rl:allow("a", 1.0))
	local first, second, third = rl:allow("a", 100), rl:allow("a", 100), rl:allow("a", 100)
	Test.eq({ first, second, third }, { true, true, false }, "refill caps at burst")
	rl:forget("a")
	Test.truthy(rl:allow("a", 100))
end)

Test.done()
