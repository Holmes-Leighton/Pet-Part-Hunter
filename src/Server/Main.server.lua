--!strict
-- Game server: builds the lobby and all six areas (spec section 4), then runs one Run (bag + chaser + escape) per
-- player who steps on an area's portal and is allowed in. All game rules live in ReplicatedStorage.Shared (and are
-- unit tested); this script only connects them to players, parts and remotes. Clients never send gameplay data:
-- the server reads positions.
--
-- Each area is a maze built at its own origin in the world. The rules work in the area's own local coordinates
-- (0,0 is the maze corner), so a player's position is converted with the origin on the way in and out.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Rng = require(Shared:WaitForChild("Rng"))
local Maze = require(Shared:WaitForChild("Maze"))
local Areas = require(Shared:WaitForChild("Areas"))
local Bag = require(Shared:WaitForChild("Bag"))
local Chaser = require(Shared:WaitForChild("Chaser"))
local EscapeTimer = require(Shared:WaitForChild("EscapeTimer"))
local PartSpawner = require(Shared:WaitForChild("PartSpawner"))
local Run = require(Shared:WaitForChild("Run"))
local Parts = require(Shared:WaitForChild("Parts"))
local Crafting = require(Shared:WaitForChild("Crafting"))

local AreaAccess = require(script.Parent:WaitForChild("AreaAccess"))
local AreaBuilder = require(script.Parent:WaitForChild("AreaBuilder"))
local ChaserModel = require(script.Parent:WaitForChild("ChaserModel"))
local CraftService = require(script.Parent:WaitForChild("CraftService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Progression = require(script.Parent:WaitForChild("Progression"))

local CELL = Config.Maze.CellSize
local AREA_SPACING = 300 -- studs between area origins along X; the biggest maze is 16 cells x 16 studs
local AREA_ORIGIN_X = 100

-- Remotes -------------------------------------------------------------------------------------------------------
local notify = Instance.new("RemoteEvent")
notify.Name = "Notify"
notify.Parent = ReplicatedStorage

-- World ---------------------------------------------------------------------------------------------------------
local world = Instance.new("Folder")
world.Name = "World"
world.Parent = workspace
local lobby = AreaBuilder.buildLobby(Config, world)
local chasers = Instance.new("Folder")
chasers.Name = "Chasers"
chasers.Parent = workspace
local partFolder = Instance.new("Folder")
partFolder.Name = "Parts"
partFolder.Parent = workspace

type AreaCtx = {
	def: Areas.Def,
	maze: any,
	layout: any,
	grid: Chaser.Grid,
	spawner: PartSpawner.PartSpawner,
	spawnPoints: { PartSpawner.Point },
	zones: { Run.Zone },
	visuals: { [number]: Part },
	folder: Folder,
	ox: number,
	oz: number,
}

local function cellLocal(c: { x: number, y: number }): (number, number)
	return Maze.cellToWorld(c.x, c.y, CELL)
end

local areaCtxs: { AreaCtx } = {}
local areaByName: { [string]: AreaCtx } = {}
local problemCount = 0

for i, def in Config.Areas :: { Areas.Def } do
	local maze, layout = Areas.generate(Config, def)
	local model = AreaBuilder.build(Maze, maze, layout, Config, world, def.name)
	-- Validate in the area's own coordinates, then move it to its place in the world.
	local problems = AreaBuilder.validate(Maze, maze, layout, Config, model)
	if #problems > 0 then
		warn("[PetPartHunter] " .. def.name .. " validation problems: " .. table.concat(problems, "; "))
	end
	problemCount += #problems
	local ox, oz = AREA_ORIGIN_X + (i - 1) * AREA_SPACING, 0
	model:TranslateBy(Vector3.new(ox, 0, oz))

	local spawnPoints: { PartSpawner.Point } = {}
	for _, c in layout.spawnCells do
		local x, z = cellLocal(c)
		table.insert(spawnPoints, { x = x, z = z })
	end
	local zones: { Run.Zone } = {}
	for _, c in layout.exits do
		local x, z = cellLocal(c)
		table.insert(zones, { x = x, z = z, radius = Config.Escape.ZoneRadius })
	end
	local folder = Instance.new("Folder")
	folder.Name = def.name
	folder.Parent = partFolder

	local ctx: AreaCtx = {
		def = def,
		maze = maze,
		layout = layout,
		grid = {
			cellSize = CELL,
			worldToCell = function(x, z)
				local cx, cy = Maze.worldToCell(x, z, CELL)
				return math.clamp(cx, 1, maze.width), math.clamp(cy, 1, maze.height)
			end,
			cellToWorld = function(cx, cy)
				return Maze.cellToWorld(cx, cy, CELL)
			end,
			findPath = function(fx, fy, tx, ty)
				return Maze.findPath(maze, fx, fy, tx, ty)
			end,
		},
		spawner = PartSpawner.new(Rng.new(def.seed + 2), spawnPoints, Areas.templates(Config, def), def.activeParts, Config.Parts.RespawnSeconds),
		spawnPoints = spawnPoints,
		zones = zones,
		visuals = {},
		folder = folder,
		ox = ox,
		oz = oz,
	}
	table.insert(areaCtxs, ctx)
	areaByName[def.name] = ctx
end
workspace:SetAttribute("AreaProblems", problemCount)

-- Shared part spawns -------------------------------------------------------------------------------------------
-- A stable colour per species (placeholder art until the meshes exist).
local function speciesColor(species: string): Color3
	local h = 0
	for i = 1, #species do
		h = (h * 31 + string.byte(species, i)) % 360
	end
	return Color3.fromHSV(h / 360, 0.65, 1)
end

local function makeVisual(ctx: AreaCtx, spawn: PartSpawner.Spawn)
	local point = ctx.spawnPoints[spawn.pointIndex]
	local p = Instance.new("Part")
	p.Name = "PetPart"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(3, 3, 3)
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.Neon
	p.Color = speciesColor(spawn.part.species)
	p.Position = Vector3.new(point.x + ctx.ox, 3, point.z + ctx.oz)
	p:SetAttribute("SpawnId", spawn.spawnId)
	p:SetAttribute("Species", spawn.part.species)
	p:SetAttribute("Slot", spawn.part.slot)
	p:SetAttribute("Rarity", spawn.part.rarity)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 40)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = spawn.part.species .. " " .. spawn.part.slot
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.Parent = gui
	p.Parent = ctx.folder
	ctx.visuals[spawn.spawnId] = p
end

local function syncVisuals(ctx: AreaCtx)
	local live: { [number]: boolean } = {}
	for _, s in ctx.spawner:activeSpawns() do
		live[s.spawnId] = true
		if ctx.visuals[s.spawnId] == nil then
			makeVisual(ctx, s)
		end
	end
	for id, p in ctx.visuals do
		if not live[id] then
			p:Destroy()
			ctx.visuals[id] = nil
		end
	end
end

-- Per-player runs ----------------------------------------------------------------------------------------------
type PlayerRun = { run: Run.Run, model: Model, lastDistance: number, area: AreaCtx }
local runs: { [Player]: PlayerRun } = {}
local enterCooldown: { [Player]: number } = {}
local rollRng = Rng.new(os.time())

local SETTINGS: Run.Settings = {
	catchRadius = Config.Chase.CatchRadius,
	protectionSeconds = Config.Chase.ProtectionSeconds,
	headStartSeconds = Config.Chase.HeadStartSeconds,
	interruptDistance = Config.Chase.InterruptDistance,
	pickupRadius = Config.Parts.PickupRadius,
}

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function teleport(player: Player, x: number, y: number, z: number)
	local char = player.Character
	if char then
		char:PivotTo(CFrame.new(x, y, z))
	end
end

local function setHud(player: Player, pr: PlayerRun?)
	if pr == nil then
		player:SetAttribute("RunState", "lobby")
		player:SetAttribute("Area", "")
		player:SetAttribute("BagCount", 0)
		player:SetAttribute("EscapeProgress", 0)
		player:SetAttribute("Protected", false)
		player:SetAttribute("ChaserDistance", 999)
		return
	end
	local run = pr.run
	player:SetAttribute("RunState", "running")
	player:SetAttribute("Area", pr.area.def.name)
	player:SetAttribute("BagCount", run.bag:count())
	player:SetAttribute("BagCapacity", run.bag.capacity)
	player:SetAttribute("EscapeProgress", math.floor(run.timer:progress() * 100))
	player:SetAttribute("Protected", run:isProtected())
	player:SetAttribute("ChaserDistance", math.floor(pr.lastDistance))
end

local function endRun(player: Player)
	local pr = runs[player]
	if pr then
		pr.model:Destroy()
		runs[player] = nil
	end
	setHud(player, nil)
end

Progression.start(AreaBuilder.buildPads(Config, world:FindFirstChild("Lobby") :: Instance), function(player)
	return runs[player] ~= nil
end, notify)
CraftService.start(function(player)
	return runs[player] ~= nil
end, notify)
AreaAccess.start(notify)

-- Chaser speed for new runs: the area's expected player speed times its tier multiplier (Shared/Areas). In Studio
-- only, the DebugChaserSpeed workspace attribute overrides it so playtests can freeze the chaser (0) or speed it up.
local function chaserSpeed(def: Areas.Def): number
	local override = workspace:GetAttribute("DebugChaserSpeed")
	if RunService:IsStudio() and type(override) == "number" then
		return override
	end
	return Areas.chaserSpeed(Config, def)
end

local function entranceWorld(ctx: AreaCtx): (number, number)
	local x, z = cellLocal(ctx.layout.entrance)
	return x + ctx.ox, z + ctx.oz
end

local function startRun(player: Player, ctx: AreaCtx)
	local data = PlayerData.get(player)
	if runs[player] or data == nil or not Areas.canEnter(data, ctx.def.name) then
		return
	end
	local sx, sz = cellLocal(ctx.layout.chaserStart)
	local run = Run.new({
		bag = Bag.new(Config.Bag.StartCapacity + Crafting.equippedStats(Config, data).bag),
		chaser = Chaser.new(ctx.grid, sx, sz, chaserSpeed(ctx.def)),
		spawner = ctx.spawner,
		timer = EscapeTimer.new(Config.Escape.HoldSeconds),
	}, ctx.zones, SETTINGS, { x = sx, z = sz })
	local model = ChaserModel.create(tostring(player.UserId), chasers)
	runs[player] = { run = run, model = model, lastDistance = 999, area = ctx }
	local ex, ez = entranceWorld(ctx)
	teleport(player, ex, 3, ez)
	setHud(player, runs[player])
	notify:FireClient(player, string.format("%s: collect parts, then reach a green EXIT and hold for %d seconds!", ctx.def.name, Config.Escape.HoldSeconds))
end

local function onCharacter(player: Player, char: Model)
	local humanoid = char:WaitForChild("Humanoid") :: Humanoid -- WalkSpeed is set by Progression from saved Speed
	-- Resetting or dying mid-run counts as being caught: the run ends and the bag is lost.
	if runs[player] then
		endRun(player)
	end
	humanoid.Died:Connect(function()
		if runs[player] then
			endRun(player)
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("Banked", 0)
	setHud(player, nil)
	player.CharacterAdded:Connect(function(char)
		onCharacter(player, char)
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end
end)
Players.PlayerRemoving:Connect(function(player)
	endRun(player)
	enterCooldown[player] = nil
end)

-- Main loop ----------------------------------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	for _, ctx in areaCtxs do
		ctx.spawner:update(dt)
		syncVisuals(ctx)
	end

	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root == nil then
			continue
		end

		local pr = runs[player]
		if pr == nil then
			-- Lobby: stepping on an area's portal starts a run there, if the player has unlocked that area.
			local p = root.Position
			if os.clock() >= (enterCooldown[player] or 0) then
				for _, portal in lobby.portals do
					local dx, dz = p.X - portal.x, p.Z - portal.z
					if dx * dx + dz * dz <= (portal.radius + 1) ^ 2 and p.Y < 8 then
						if AreaAccess.check(player, portal.name) then
							startRun(player, areaByName[portal.name])
						end
						break
					end
				end
			end
			continue
		end

		local ctx = pr.area
		local px, pz = root.Position.X - ctx.ox, root.Position.Z - ctx.oz
		-- Auto-pickup: any part in range goes into the bag if there is room.
		for _, s in ctx.spawner:activeSpawns() do
			local ok = pr.run:tryPickup(s.spawnId, px, pz)
			if ok then
				notify:FireClient(player, string.format("Picked up %s %s (%d/%d)", s.part.species, s.part.slot, pr.run.bag:count(), pr.run.bag.capacity))
			end
		end

		for _, e in pr.run:update(dt, px, pz) do
			if e.type == "caught" then
				local lost = e.lost or {}
				local ex, ez = entranceWorld(ctx)
				teleport(player, ex, 3, ez)
				notify:FireClient(player, string.format("CAUGHT! You lost %d part(s). Back to the start.", #lost))
			elseif e.type == "escaped" then
				local parts = e.parts or {}
				local data = PlayerData.get(player)
				if data then
					for _, part in parts do
						-- Bag parts are spawn instances (id "part-N"); the catalog id is Species_Slot.
						local def = Parts.get(part.species .. "_" .. part.slot)
						if def then
							Crafting.addPart(Config, data, def, rollRng, os.time())
						end
					end
					CraftService.push(player)
				end
				enterCooldown[player] = os.clock() + 3
				endRun(player)
				teleport(player, lobby.spawn.X, lobby.spawn.Y, lobby.spawn.Z)
				notify:FireClient(player, string.format("ESCAPED with %d part(s)!", #parts))
				break
			end
		end

		pr = runs[player]
		if pr then
			local cx, cz = pr.run.chaser:position()
			pr.lastDistance = pr.run.chaser:distanceTo(px, pz)
			ChaserModel.place(pr.model, cx + ctx.ox, cz + ctx.oz, px + ctx.ox, pz + ctx.oz, os.clock())
			setHud(player, pr)
		end
	end
end)
