--!strict
local Test = require("./harness")
local Config = require("../src/Shared/Config")
local Speed = require("../src/Shared/Speed")

Test.case("spec values: bag of 3, 2 second escape hold", function()
	Test.eq(Config.Bag.StartCapacity, 3)
	Test.eq(Config.Escape.HoldSeconds, 2)
end)

Test.case("chaser speed rises with the area tier and the Common chaser is slower than the player", function()
	local m = Config.Chase.SpeedMultiplier
	Test.truthy(m.Common < m.Uncommon and m.Uncommon < m.Rare, "tiers get faster")
	Test.truthy(m.Common < 1, "Common is escapable at the expected speed")
end)

Test.case("the player can fit through a corridor, and pads fit the corridor width", function()
	local corridor = Config.Maze.CellSize - Config.Maze.WallThickness
	Test.truthy(corridor >= 10, "corridor wide enough for a character")
	Test.truthy(Config.Escape.ZoneRadius * 2 <= corridor, "exit pad fits in the corridor")
end)

Test.case("there are enough spawn cells for the active part count", function()
	Test.truthy(Config.Area.SpawnCells >= Config.Parts.ActiveCount * 2)
end)

Test.case("the catch radius is smaller than the interrupt distance", function()
	Test.truthy(Config.Chase.CatchRadius < Config.Chase.InterruptDistance)
end)

Test.case("the Common chaser is tuned for a brand-new player (level 1 WalkSpeed)", function()
	Test.eq(Config.Player.WalkSpeed, Speed.walkSpeed(Config.Speed, 1))
end)

Test.case("the WalkSpeed cap leaves headroom under the anti-cheat ceiling and is reachable by rebirthing", function()
	Test.truthy(Config.Speed.WalkCap < Config.Speed.AntiCheatCeiling)
	local capLevel = math.ceil((Config.Speed.WalkCap - Config.Speed.BaseWalk) / Config.Speed.WalkPerLevel)
	Test.truthy(capLevel <= Speed.levelCap(Config.Speed, Config.Speed.MaxRebirths))
end)

Test.case("pad tiers get faster and cost more, and the starter pad is free", function()
	local prevRate, prevCoins = 0, -1
	for i, p in Config.Pads do
		Test.eq(p.tier, i)
		Test.truthy(p.rate > prevRate and p.coins > prevCoins, "tier " .. i)
		prevRate, prevCoins = p.rate, p.coins
	end
	Test.eq(Config.Pads[1].coins, 0)
end)

Test.done()
