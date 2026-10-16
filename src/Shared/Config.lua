--!strict
-- Tunable numbers for the chase prototype. Values marked (spec) come from docs/GAME_DESIGN_SPEC.md,
-- the rest are starting points to tune in playtests.

local Config = {
	Player = {
		WalkSpeed = 12, -- studs/s; expected player speed in Common = a brand-new player (level 1); chaser speeds are set against it
	},

	-- Speed, levels and rebirth (spec section 3). Formulas live in Shared/Speed.
	Speed = {
		BaseLevelCost = 100, -- (spec, observed) Speed needed to finish level 1
		LevelCostGrowth = 1.15, -- (spec, observed) each level costs 15% more
		BaseWalk = 10, -- (spec, observed) WalkSpeed = BaseWalk + WalkPerLevel * level, capped
		WalkPerLevel = 2,
		WalkCap = 60, -- proposed; headroom above the Common-Rare chaser tiers, below the anti-cheat ceiling
		AntiCheatCeiling = 80, -- the server never lets WalkSpeed exceed this, whatever the data says
		LevelsPerRebirth = 15, -- (spec) Rebirth 1 needs level 15, Rebirth 5 needs level 75; also the level cap
		RebirthLinearSteps = 5, -- x(1 + 0.5r) up to Rebirth 5 (x3.5), then x1.2 per rebirth
		RebirthLinearStep = 0.5,
		RebirthLateGrowth = 1.2,
		MaxRebirths = 10, -- the ladder ends here; Apex comes after launch tuning
		PassMultiplier = 2, -- 2x speed gain pass; never raises the WalkSpeed cap
	},

	-- Running pads at home (spec section 3). rate = Speed per second; coin prices are proposed.
	Pads = {
		{ tier = 1, rate = 1, coins = 0, rebirths = 0 },
		{ tier = 2, rate = 25, coins = 500, rebirths = 0 },
		{ tier = 3, rate = 50, coins = 2500, rebirths = 0 },
		{ tier = 4, rate = 100, coins = 10000, rebirths = 0 },
		{ tier = 5, rate = 250, coins = 50000, rebirths = 1 },
		{ tier = 6, rate = 500, coins = 250000, rebirths = 2 },
	},

	-- Part stat points rolled per rarity (spec section 5). Each part rolls one quality value in [min, max], which the
	-- slot's stat weights (Shared/Parts) turn into speed / bag / coin / luck. Starting values to tune.
	Rarity = {
		Common = { min = 1, max = 3 },
		Uncommon = { min = 3, max = 6 },
		Rare = { min = 6, max = 10 },
		SuperRare = { min = 10, max = 16 },
		Legendary = { min = 16, max = 25 },
		Mythic = { min = 25, max = 40 },
	},

	-- Quality tiers from merging (spec section 5): working names, each raises a part's stats by a set percentage.
	Tiers = {
		{ name = "Standard", multiplier = 1 },
		{ name = "Polished", multiplier = 1.25 },
		{ name = "Brilliant", multiplier = 1.6 },
	},
	MergeCount = 5, -- (spec) same part, same tier

	Pets = {
		BuildFee = 50, -- coins; proposed pet-building sink
		StartSlots = 2, -- (spec) equipped pets at the start, buyable up to MaxSlots
		MaxSlots = 6,
		-- Per-stat caps on a finished pet (spec: stats are summed, then capped to protect balance).
		-- speed/coin/luck are percentages; bag is extra bag slots.
		Caps = { speed = 100, coin = 100, luck = 100, bag = 3 },
	},

	-- Remote rate limits (spec section 9).
	RateLimit = {
		Rebirth = { perSecond = 0.5, burst = 2 },
		BuyPad = { perSecond = 1, burst = 3 },
		Craft = { perSecond = 2, burst = 5 },
	},

	Data = {
		StoreName = "PetPartHunterProfiles_v1",
		SchemaVersion = 1,
		AutosaveSeconds = 60,
		LockSeconds = 120, -- a session lock older than this is treated as a crashed server
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

	Area = {
		Seed = 1, -- fixed so the Common maze is the same every server while we tune it
		Width = 11, -- cells
		Height = 11,
		ExitCount = 3,
		MinExitSeparation = 8, -- maze steps between exits and from the entrance
		SpawnCells = 30, -- candidate cells for parts
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
