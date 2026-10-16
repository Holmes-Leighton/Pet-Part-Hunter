--!strict
local Test = require("./harness")
local Speed = require("../src/Shared/Speed")
local Config = require("../src/Shared/Config")

local S = Config.Speed

Test.case("level costs match the observed Keyboard Escape values", function()
	local observed = { 100, 115, 132, 152, 175 }
	for n, cost in observed do
		Test.near(math.floor(Speed.levelCost(S, n) + 0.5), cost, 1, "level " .. n)
	end
end)

Test.case("the walk speeds match the observed table (12, 14, 16, 18, 20)", function()
	for level, walk in { 12, 14, 16, 18, 20 } do
		Test.eq(Speed.walkSpeed(S, level), walk)
	end
end)

Test.case("total speed shown: 62 into level 2 is 162; level 15 needs about 4,000", function()
	Test.near(Speed.totalForLevel(S, 2) + 62, 162, 0.01)
	Test.truthy(math.abs(Speed.totalForLevel(S, 15) - 4050) < 100, "level 15 threshold ~ 4,000")
end)

Test.case("levelFromTotal inverts totalForLevel exactly at and around every threshold", function()
	for n = 1, 200 do
		local at = Speed.totalForLevel(S, n)
		Test.eq(Speed.levelFromTotal(S, at), n, "at level " .. n)
		if n > 1 then
			Test.eq(Speed.levelFromTotal(S, at * (1 - 1e-9) - 1e-6), n - 1, "just below level " .. n)
		end
	end
	Test.eq(Speed.levelFromTotal(S, 0), 1)
	Test.eq(Speed.levelFromTotal(S, -5), 1)
end)

Test.case("level progress reports speed into the level and its cost (72 / 100)", function()
	local into, cost = Speed.levelProgress(S, 72)
	Test.near(into, 72, 1e-9)
	Test.near(cost, 100, 1e-9)
end)

Test.case("walk speed is capped, and never above the anti-cheat ceiling", function()
	Test.eq(Speed.walkSpeed(S, 1000), S.WalkCap)
	Test.truthy(S.WalkCap <= S.AntiCheatCeiling)
	Test.eq(Speed.walkSpeed(S, 1), 12)
end)

Test.case("rebirth multiplier: x1.5 at 1, x3.5 at 5 (spec), then steeper, always rising", function()
	Test.eq(Speed.rebirthMultiplier(S, 0), 1)
	Test.near(Speed.rebirthMultiplier(S, 1), 1.5)
	Test.near(Speed.rebirthMultiplier(S, 5), 3.5)
	local prev = 0.0
	for r = 0, S.MaxRebirths do
		local m = Speed.rebirthMultiplier(S, r)
		Test.truthy(m > prev, "rising at " .. r)
		prev = m
	end
	Test.truthy(Speed.rebirthMultiplier(S, 8) > 5, "about x6 at Rebirth 8")
end)

Test.case("rebirth thresholds: level 15 for the first, 75 for the fifth", function()
	Test.eq(Speed.levelCap(S, 0), 15)
	Test.eq(Speed.levelCap(S, 4), 75)
	Test.truthy(not Speed.canRebirth(S, Speed.totalForLevel(S, 14), 0))
	Test.truthy(Speed.canRebirth(S, Speed.totalForLevel(S, 15), 0))
	Test.truthy(not Speed.canRebirth(S, Speed.totalForLevel(S, 15), 1), "next rebirth needs more")
	Test.truthy(not Speed.canRebirth(S, math.huge, S.MaxRebirths), "ladder ends")
end)

Test.done()
