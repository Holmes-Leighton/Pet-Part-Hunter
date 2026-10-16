--!strict
-- The six World 1 areas as rules (spec section 4): looking one up, generating its maze, its chaser speed, its part
-- pool, and who may enter. Pure logic over Config.Areas and the player's saved data, so it is tested without Roblox.
--
-- Access: Common, Uncommon and Rare are free. Super Rare, Legendary and Mythic open with a game pass (early access)
-- or a rebirth count (the free route). Unlocks are permanent: once earned they are stored in data.areas and survive
-- a later Apex reset (spec: "unlocks are permanent and stored in the player profile").

local AreaLayout = require("./AreaLayout")
local Maze = require("./Maze")
local Parts = require("./Parts")
local Rng = require("./Rng")

local Areas = {}

export type Def = {
	name: string,
	seed: number,
	width: number,
	height: number,
	exitCount: number,
	minExitSeparation: number,
	spawnCells: number,
	activeParts: number,
	expectedWalk: number,
	pool: { [string]: number },
	specialWeight: number?,
	combat: boolean?,
	unlockRebirths: number?,
	pass: string?,
}

export type Settings = { Areas: any, Passes: any, Chase: any, Maze: any, Parts: any }

function Areas.get(cfg: Settings, name: string): Def?
	for _, def in cfg.Areas do
		if def.name == name then
			return def
		end
	end
	return nil
end

function Areas.names(cfg: Settings): { string }
	local out = {}
	for _, def in cfg.Areas do
		table.insert(out, def.name)
	end
	return out
end

function Areas.index(cfg: Settings, name: string): number?
	for i, def in cfg.Areas do
		if def.name == name then
			return i
		end
	end
	return nil
end

-- Studs per second the area's chaser runs at: the expected player speed there times the tier multiplier.
function Areas.chaserSpeed(cfg: Settings, def: Def): number
	return def.expectedWalk * cfg.Chase.SpeedMultiplier[def.name]
end

-- The same maze and layout on every server (fixed seeds), so the area can be tuned and tested.
function Areas.generate(cfg: Settings, def: Def): (any, AreaLayout.Layout)
	local maze = Maze.generate(def.width, def.height, Rng.new(def.seed), cfg.Maze.LoopFraction)
	local layout = AreaLayout.generate(Maze, maze, Rng.new(def.seed + 1), {
		exitCount = def.exitCount,
		spawnCount = def.spawnCells,
		minExitSeparation = def.minExitSeparation,
	})
	return maze, layout
end

-- Weighted part templates for PartSpawner.
function Areas.templates(cfg: Settings, def: Def): { Parts.Template }
	return Parts.templates(def.pool, def.specialWeight or cfg.Parts.SpecialWeight)
end

export type Data = { rebirths: number, passes: { [string]: boolean }, areas: { [string]: boolean } }

local function isFree(def: Def): boolean
	return def.unlockRebirths == nil and def.pass == nil
end

-- Why an area is (or is not) open, ignoring what is already stored: "free", "rebirth", "pass" or nil.
function Areas.unlockReason(def: Def, data: Data): string?
	if isFree(def) then
		return "free"
	end
	if def.unlockRebirths and data.rebirths >= def.unlockRebirths then
		return "rebirth"
	end
	if (def.pass and data.passes[def.pass]) or data.passes.AllAreas then
		return "pass"
	end
	return nil
end

-- Stores any unlocks the player has newly earned (call after load, a rebirth or a pass grant). Returns the names
-- that were just unlocked, so the server can tell the player.
function Areas.refreshUnlocks(cfg: Settings, data: Data): { string }
	local fresh = {}
	for _, def in cfg.Areas do
		if not data.areas[def.name] and Areas.unlockReason(def, data) then
			data.areas[def.name] = true
			table.insert(fresh, def.name)
		end
	end
	return fresh
end

function Areas.canEnter(data: Data, name: string): boolean
	return data.areas[name] == true
end

-- A short line telling a locked-out player how to get in.
function Areas.lockedHint(def: Def): string
	local parts = {}
	if def.unlockRebirths then
		table.insert(parts, "reach Rebirth " .. def.unlockRebirths)
	end
	if def.pass then
		table.insert(parts, "buy early access")
	end
	return def.name .. " is locked: " .. table.concat(parts, " or ")
end

return Areas
