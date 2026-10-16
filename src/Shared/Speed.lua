--!strict
-- Speed, levels, WalkSpeed and rebirth maths (spec section 3). Pure functions over the numbers in Config.Speed.
-- "Speed" is a running total that can grow huge; the level (and so WalkSpeed) follows it more slowly.

local Speed = {}

export type Settings = {
	BaseLevelCost: number,
	LevelCostGrowth: number,
	BaseWalk: number,
	WalkPerLevel: number,
	WalkCap: number,
	AntiCheatCeiling: number,
	LevelsPerRebirth: number,
	RebirthLinearSteps: number,
	RebirthLinearStep: number,
	RebirthLateGrowth: number,
	MaxRebirths: number,
	PassMultiplier: number,
}

-- Speed needed to finish level n (100, 115, 132, 152, 175 ... as observed).
function Speed.levelCost(cfg: Settings, n: number): number
	return cfg.BaseLevelCost * cfg.LevelCostGrowth ^ (n - 1)
end

-- Total Speed at which a player reaches level n (level 1 starts at 0).
function Speed.totalForLevel(cfg: Settings, n: number): number
	if n <= 1 then
		return 0
	end
	return cfg.BaseLevelCost * (cfg.LevelCostGrowth ^ (n - 1) - 1) / (cfg.LevelCostGrowth - 1)
end

function Speed.levelFromTotal(cfg: Settings, total: number): number
	if total <= 0 then
		return 1
	end
	local g = cfg.LevelCostGrowth
	local n = math.floor(math.log(total * (g - 1) / cfg.BaseLevelCost + 1) / math.log(g)) + 1
	-- Floating point can land one off at an exact boundary; settle it against the real thresholds.
	while Speed.totalForLevel(cfg, n + 1) <= total do
		n += 1
	end
	while n > 1 and Speed.totalForLevel(cfg, n) > total do
		n -= 1
	end
	return n
end

-- Speed into the current level and what that level costs, for the HUD bar ("72 / 100").
function Speed.levelProgress(cfg: Settings, total: number): (number, number)
	local level = Speed.levelFromTotal(cfg, total)
	return total - Speed.totalForLevel(cfg, level), Speed.levelCost(cfg, level)
end

function Speed.walkSpeed(cfg: Settings, level: number): number
	local w = math.min(cfg.BaseWalk + cfg.WalkPerLevel * level, cfg.WalkCap)
	return math.min(w, cfg.AntiCheatCeiling)
end

-- The level a player must reach for their next rebirth; also the highest level they can train to meanwhile.
function Speed.levelCap(cfg: Settings, rebirths: number): number
	return cfg.LevelsPerRebirth * (rebirths + 1)
end

-- Permanent Speed-gain multiplier: x1.5 at Rebirth 1 and x3.5 at Rebirth 5 (spec), then steeper.
function Speed.rebirthMultiplier(cfg: Settings, rebirths: number): number
	local linear = math.min(rebirths, cfg.RebirthLinearSteps)
	local m = 1 + cfg.RebirthLinearStep * linear
	if rebirths > cfg.RebirthLinearSteps then
		m *= cfg.RebirthLateGrowth ^ (rebirths - cfg.RebirthLinearSteps)
	end
	return m
end

function Speed.canRebirth(cfg: Settings, total: number, rebirths: number): boolean
	return rebirths < cfg.MaxRebirths and Speed.levelFromTotal(cfg, total) >= Speed.levelCap(cfg, rebirths)
end

-- Highest total Speed a player can hold before their next rebirth (they stop gaining at the level cap).
function Speed.totalCap(cfg: Settings, rebirths: number): number
	return Speed.totalForLevel(cfg, Speed.levelCap(cfg, rebirths))
end

return Speed
