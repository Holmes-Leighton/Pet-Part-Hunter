--!strict
local Test = require("./harness")
local Config = require("../src/Shared/Config")

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

Test.done()
