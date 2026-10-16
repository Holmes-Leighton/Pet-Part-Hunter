--!strict
-- Chase prototype server: builds the Common area, then runs one Run (bag + chaser + escape) per player who steps
-- on the lobby pad. All game rules live in ReplicatedStorage.Shared (and are unit tested); this script only
-- connects them to players, parts and remotes. Clients never send gameplay data: the server reads positions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Rng = require(Shared:WaitForChild("Rng"))
local Maze = require(Shared:WaitForChild("Maze"))
local AreaLayout = require(Shared:WaitForChild("AreaLayout"))
local Bag = require(Shared:WaitForChild("Bag"))
local Chaser = require(Shared:WaitForChild("Chaser"))
local EscapeTimer = require(Shared:WaitForChild("EscapeTimer"))
local PartSpawner = require(Shared:WaitForChild("PartSpawner"))
local Run = require(Shared:WaitForChild("Run"))

local AreaBuilder = require(script.Parent:WaitForChild("AreaBuilder"))
local ChaserModel = require(script.Parent:WaitForChild("ChaserModel"))
local Progression = require(script.Parent:WaitForChild("Progression"))

local CELL = Config.Maze.CellSize
local AREA = "Common"

-- Placeholder part types for the prototype (real species come with the part pipeline).
local CATALOG: { PartSpawner.Template } = {
	{ species = "Chicken", slot = "Head", rarity = "Common" },
	{ species = "Tiger", slot = "Legs", rarity = "Common" },
	{ species = "Frog", slot = "Body", rarity = "Common" },
	{ species = "Fox", slot = "Tail", rarity = "Common" },
	{ species = "Owl", slot = "Special", rarity = "Common", weight = 0.5 },
}
local SPECIES_COLOR: { [string]: Color3 } = {
	Chicken = Color3.fromRGB(255, 220, 90),
	Tiger = Color3.fromRGB(255, 140, 40),
	Frog = Color3.fromRGB(90, 220, 90),
	Fox = Color3.fromRGB(235, 90, 50),
	Owl = Color3.fromRGB(190, 140, 255),
}

-- Remotes -------------------------------------------------------------------------------------------------------
local notify = Instance.new("RemoteEvent")
notify.Name = "Notify"
notify.Parent = ReplicatedStorage

-- World ---------------------------------------------------------------------------------------------------------
local maze = Maze.generate(Config.Area.Width, Config.Area.Height, Rng.new(Config.Area.Seed), Config.Maze.LoopFraction)
local layout = AreaLayout.generate(Maze, maze, Rng.new(Config.Area.Seed + 1), {
	exitCount = Config.Area.ExitCount,
	spawnCount = Config.Area.SpawnCells,
	minExitSeparation = Config.Area.MinExitSeparation,
})

local world = Instance.new("Folder")
world.Name = "World"
world.Parent = workspace
local areaModel = AreaBuilder.build(Maze, maze, layout, Config, world)
local lobby = AreaBuilder.buildLobby(Config, world)
local chasers = Instance.new("Folder")
chasers.Name = "Chasers"
chasers.Parent = workspace
local partFolder = Instance.new("Folder")
partFolder.Name = "Parts"
partFolder.Parent = workspace

local problems = AreaBuilder.validate(Maze, maze, layout, Config, areaModel)
if #problems > 0 then
	warn("[PetPartHunter] area validation problems: " .. table.concat(problems, "; "))
end
workspace:SetAttribute("AreaProblems", #problems)

local function cellWorld(c: AreaLayout.Cell): (number, number)
	return Maze.cellToWorld(c.x, c.y, CELL)
end

local grid: Chaser.Grid = {
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
}

-- Shared part spawns -------------------------------------------------------------------------------------------
local spawnPoints: { PartSpawner.Point } = {}
for _, c in layout.spawnCells do
	local x, z = cellWorld(c)
	table.insert(spawnPoints, { x = x, z = z })
end
local spawner = PartSpawner.new(Rng.new(Config.Area.Seed + 2), spawnPoints, CATALOG, Config.Parts.ActiveCount, Config.Parts.RespawnSeconds)

local visuals: { [number]: Part } = {}

local function makeVisual(spawn: PartSpawner.Spawn)
	local point = spawnPoints[spawn.pointIndex]
	local p = Instance.new("Part")
	p.Name = "PetPart"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(3, 3, 3)
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.Neon
	p.Color = SPECIES_COLOR[spawn.part.species] or Color3.new(1, 1, 1)
	p.Position = Vector3.new(point.x, 3, point.z)
	p:SetAttribute("SpawnId", spawn.spawnId)
	p:SetAttribute("Species", spawn.part.species)
	p:SetAttribute("Slot", spawn.part.slot)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(110, 34)
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
	p.Parent = partFolder
	visuals[spawn.spawnId] = p
end

local function syncVisuals()
	local live: { [number]: boolean } = {}
	for _, s in spawner:activeSpawns() do
		live[s.spawnId] = true
		if visuals[s.spawnId] == nil then
			makeVisual(s)
		end
	end
	for id, p in visuals do
		if not live[id] then
			p:Destroy()
			visuals[id] = nil
		end
	end
end

-- Per-player runs ----------------------------------------------------------------------------------------------
type PlayerRun = { run: Run.Run, model: Model, lastDistance: number }
local runs: { [Player]: PlayerRun } = {}
local enterCooldown: { [Player]: number } = {}

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
		player:SetAttribute("BagCount", 0)
		player:SetAttribute("EscapeProgress", 0)
		player:SetAttribute("Protected", false)
		player:SetAttribute("ChaserDistance", 999)
		return
	end
	local run = pr.run
	player:SetAttribute("RunState", "running")
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

-- Chaser speed for new runs. In Studio only, the DebugChaserSpeed workspace attribute overrides it so playtests
-- can freeze the chaser (0) or speed it up without editing code.
local function chaserSpeed(): number
	local override = workspace:GetAttribute("DebugChaserSpeed")
	if RunService:IsStudio() and type(override) == "number" then
		return override
	end
	return Config.Player.WalkSpeed * Config.Chase.SpeedMultiplier[AREA]
end

local function startRun(player: Player)
	if runs[player] then
		return
	end
	local ex, ez = cellWorld(layout.entrance)
	local sx, sz = cellWorld(layout.chaserStart)
	local run = Run.new({
		bag = Bag.new(Config.Bag.StartCapacity),
		chaser = Chaser.new(grid, sx, sz, chaserSpeed()),
		spawner = spawner,
		timer = EscapeTimer.new(Config.Escape.HoldSeconds),
	}, (function()
		local zones = {}
		for _, c in layout.exits do
			local x, z = cellWorld(c)
			table.insert(zones, { x = x, z = z, radius = Config.Escape.ZoneRadius })
		end
		return zones
	end)(), SETTINGS, { x = sx, z = sz })
	local model = ChaserModel.create(tostring(player.UserId), chasers)
	runs[player] = { run = run, model = model, lastDistance = 999 }
	teleport(player, ex, 3, ez)
	setHud(player, runs[player])
	notify:FireClient(player, "Collect parts, then reach a green EXIT and hold for 2 seconds!")
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
	spawner:update(dt)
	syncVisuals()

	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root == nil then
			continue
		end

		local pr = runs[player]
		if pr == nil then
			-- Lobby: stepping on the pad starts a run.
			local p = root.Position
			if (Vector3.new(p.X, 0, p.Z) - Vector3.new(lobby.enterPad.X, 0, lobby.enterPad.Z)).Magnitude <= 6 then
				if os.clock() >= (enterCooldown[player] or 0) then
					startRun(player)
				end
			end
			continue
		end

		local px, pz = root.Position.X, root.Position.Z
		-- Auto-pickup: any part in range goes into the bag if there is room.
		for _, s in spawner:activeSpawns() do
			local ok = pr.run:tryPickup(s.spawnId, px, pz)
			if ok then
				notify:FireClient(player, string.format("Picked up %s %s (%d/%d)", s.part.species, s.part.slot, pr.run.bag:count(), pr.run.bag.capacity))
			end
		end

		for _, e in pr.run:update(dt, px, pz) do
			if e.type == "caught" then
				local lost = e.lost or {}
				local ex, ez = cellWorld(layout.entrance)
				teleport(player, ex, 3, ez)
				notify:FireClient(player, string.format("CAUGHT! You lost %d part(s). Back to the start.", #lost))
			elseif e.type == "escaped" then
				local parts = e.parts or {}
				player:SetAttribute("Banked", (player:GetAttribute("Banked") :: number) + #parts)
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
			ChaserModel.place(pr.model, cx, cz, px, pz, os.clock())
			setHud(player, pr)
		end
	end
end)
