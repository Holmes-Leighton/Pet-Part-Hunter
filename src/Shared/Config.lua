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
	Rarity = ({
		Common = { min = 1, max = 3 },
		Uncommon = { min = 3, max = 6 },
		Rare = { min = 6, max = 10 },
		SuperRare = { min = 10, max = 16 },
		Legendary = { min = 16, max = 25 },
		Mythic = { min = 25, max = 40 },
	} :: any),

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

	-- Home plots (spec section 2). One fixed plot per player: a starter room on a grid of cells. Floor and ceiling items
	-- sit on cells; wall items sit on one of the four walls by (along-wall cell, height row).
	House = {
		CellSize = 2, -- studs per grid cell
		Width = 16, -- cells along X (north and south walls)
		Depth = 16, -- cells along Z (east and west walls)
		WallRows = 5, -- wall height in cells
		ItemLimit = 150, -- (spec) placed items per plot, protects mobile performance
		ExpansionBonus = 100, -- extra items with the HouseExpansion pass (proposed)
		MaxVisitors = 8, -- people the owner can allow in
		Door = { wall = 2, start = 6, width = 3, rows = 4, clearance = 2 }, -- south wall; clearance = floor rows kept free inside
		PlotCount = 16, -- plots per server
		PlotOrigin = { x = -400, z = -400 }, -- first plot corner; plots lie in rows of 8
		PlotSpacing = 60,
		PlotsPerRow = 8,
		Variants = 4, -- colour variants per item (0 = the default colour)
		WallThickness = 1, -- studs
		WallItemDepth = 0.5, -- studs a wall item sticks out
		SchemaVersion = 1,
	},

	-- Furniture catalog (spec section 2). surface: floor / wall / ceiling. w x d is the footprint in cells (for wall
	-- items: cells along the wall x rows tall). h is the model height in studs. coins = price (basic furniture is bought
	-- with coins); premium items are Robux cosmetics: not bought with coins, not tradable. Placeholder boxes until art.
	Furniture = ({
		{ id = "Chair", name = "Chair", surface = "floor", w = 1, d = 1, h = 3, coins = 25, color = { 170, 110, 60 } },
		{ id = "Plant", name = "Plant", surface = "floor", w = 1, d = 1, h = 4, coins = 20, color = { 70, 170, 80 } },
		{ id = "Fridge", name = "Fridge", surface = "floor", w = 1, d = 1, h = 6, coins = 120, color = { 220, 225, 235 } },
		{ id = "Table", name = "Table", surface = "floor", w = 2, d = 2, h = 3, coins = 60, color = { 150, 100, 55 } },
		{ id = "Bookcase", name = "Bookcase", surface = "floor", w = 2, d = 1, h = 7, coins = 80, color = { 120, 80, 50 } },
		{ id = "Wardrobe", name = "Wardrobe", surface = "floor", w = 2, d = 1, h = 7, coins = 140, color = { 100, 70, 110 } },
		{ id = "Bed", name = "Bed", surface = "floor", w = 2, d = 3, h = 3, coins = 100, color = { 90, 140, 220 } },
		{ id = "Sofa", name = "Sofa", surface = "floor", w = 3, d = 1, h = 3, coins = 150, color = { 200, 80, 90 } },
		{ id = "Piano", name = "Piano", surface = "floor", w = 2, d = 2, h = 4, coins = 400, color = { 30, 30, 36 } },
		{ id = "Clock", name = "Wall Clock", surface = "wall", w = 1, d = 1, h = 1, coins = 30, color = { 240, 220, 150 } },
		{ id = "Painting", name = "Painting", surface = "wall", w = 2, d = 2, h = 1, coins = 40, color = { 220, 170, 90 } },
		{ id = "Mirror", name = "Mirror", surface = "wall", w = 1, d = 2, h = 1, coins = 50, color = { 170, 210, 235 } },
		{ id = "Shelf", name = "Shelf", surface = "wall", w = 3, d = 1, h = 1, coins = 60, color = { 130, 90, 55 } },
		{ id = "TrophyBoard", name = "Trophy Board", surface = "wall", w = 3, d = 2, h = 1, coins = 200, color = { 200, 170, 60 } },
		{ id = "Lamp", name = "Hanging Lamp", surface = "ceiling", w = 1, d = 1, h = 2, coins = 40, color = { 255, 230, 150 } },
		{ id = "Fan", name = "Ceiling Fan", surface = "ceiling", w = 2, d = 2, h = 1, coins = 150, color = { 200, 200, 210 } },
		{ id = "Chandelier", name = "Chandelier", surface = "ceiling", w = 2, d = 2, h = 3, coins = 220, color = { 255, 215, 120 } },
		{ id = "CandySofa", name = "Candy Sofa", surface = "floor", w = 3, d = 1, h = 3, premium = true, robux = 99, color = { 255, 120, 190 } },
		{ id = "CandyLamp", name = "Candy Lamp", surface = "ceiling", w = 1, d = 1, h = 2, premium = true, robux = 49, color = { 255, 150, 90 } },
		{ id = "CandyPainting", name = "Candy Painting", surface = "wall", w = 2, d = 2, h = 1, premium = true, robux = 59, color = { 190, 120, 255 } },
	} :: any),

	-- Remote rate limits (spec section 9).
	RateLimit = {
		Home = { perSecond = 4, burst = 8 },
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

	-- The six World 1 areas, in rarity order (spec section 4). Teleport-out spacing is the main difficulty lever:
	-- fewer and further apart in higher areas. Seeds are fixed so every server has the same mazes while we tune.
	--   expectedWalk: the WalkSpeed a player is expected to have there; the chaser runs at expectedWalk x SpeedMultiplier.
	--   An area's name is the HIGHEST rarity that spawns there (Shared/Areas.rarityShares): lower rarities spawn too.
	--   unlockRebirths / pass: the free route (a rebirth count) and the early-access game pass key (Config.Passes).
	Areas = ({
		{ name = "Common", seed = 1, width = 11, height = 11, exitCount = 3, minExitSeparation = 8, spawnCells = 30, activeParts = 5, expectedWalk = 12 },
		{ name = "Uncommon", seed = 2, width = 12, height = 12, exitCount = 3, minExitSeparation = 9, spawnCells = 34, activeParts = 5, expectedWalk = 20 },
		{ name = "Rare", seed = 3, width = 13, height = 13, exitCount = 3, minExitSeparation = 10, spawnCells = 38, activeParts = 5, expectedWalk = 30, combat = true },
		{ name = "SuperRare", seed = 4, width = 14, height = 14, exitCount = 3, minExitSeparation = 11, spawnCells = 42, activeParts = 5, expectedWalk = 40, combat = true, unlockRebirths = 2, pass = "Area_SuperRare" },
		{ name = "Legendary", seed = 5, width = 15, height = 15, exitCount = 2, minExitSeparation = 12, spawnCells = 46, activeParts = 5, expectedWalk = 50, combat = true, unlockRebirths = 4, pass = "Area_Legendary" },
		{ name = "Mythic", seed = 6, width = 16, height = 16, exitCount = 2, minExitSeparation = 13, spawnCells = 50, activeParts = 5, expectedWalk = 60, combat = true, unlockRebirths = 6, pass = "Area_Mythic" },
	} :: any),

	-- Game pass IDs for early access to the paid areas (spec section 7). 0 = not set up yet: set the real Roblox IDs
	-- here. "AllAreas" is the discounted bundle and unlocks every paid area.
	Passes = {
		Area_SuperRare = 0,
		Area_Legendary = 0,
		Area_Mythic = 0,
		AllAreas = 0,
	},

	Chase = {
		-- Chaser speed relative to the expected player speed in that area (spec section 4).
		SpeedMultiplier = ({
			Common = 0.85,
			Uncommon = 0.95,
			Rare = 1.05,
			SuperRare = 1.15,
			Legendary = 1.25,
			Mythic = 1.35,
		} :: any),
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
		TopShare = 0.10, -- share of finds that are the area's own (highest) rarity; the rest is split over the lower rarities
		LowerDecay = 0.8, -- each rarity further below the top gets this fraction of the weight of the one above it (1 = equal split)
		SpecialDrift = 0.03, -- share of finds that are Special parts of rarities ABOVE the area (spec: any area, low rates)
	},
}

return Config
