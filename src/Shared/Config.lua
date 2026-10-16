--!strict
-- Tunable numbers for the chase prototype. Values marked (spec) come from docs/GAME_DESIGN_SPEC.md,
-- the rest are starting points to tune in playtests.

local Config = {
	Player = {
		WalkSpeed = 16, -- studs/s; prototype stand-in for the speed-pad curve (spec section 3)
	},

	Bag = {
		StartCapacity = 3, -- (spec)
	},

	Maze = {
		CellSize = 16, -- studs between wall centres; one corridor
		WallHeight = 14,
		WallThickness = 2,
		FloorThickness = 2,
		LoopFraction = 0.12, -- share of interior walls knocked out so there are loops to run around (spec)
	},

	Chase = {
		-- Chaser speed relative to the expected player speed in that area (spec section 4).
		SpeedMultiplier = {
			Common = 0.85,
			Uncommon = 0.95,
			Rare = 1.05,
		},
		CatchRadius = 3, -- studs between chaser and player centres
		ProtectionSeconds = 3, -- no catch right after respawning at the entrance (spec)
		HeadStartSeconds = 2, -- chaser waits this long at the start of a run
		InterruptDistance = 8, -- a chaser this close breaks an escape in progress (spec)
	},

	Escape = {
		HoldSeconds = 2, -- (spec)
		ZoneRadius = 5,
	},

	Parts = {
		PickupRadius = 5,
		RespawnSeconds = 20,
		ActiveCount = 5, -- prototype: five placeholder parts
	},
}

return Config
