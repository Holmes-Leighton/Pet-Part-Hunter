--!strict
-- Turns a maze + layout into real parts: floor, walls, entrance, glowing exit pads and the lobby.
-- All geometry is plain anchored Parts so every piece can be checked with AreaBuilder.validate.

local AreaBuilder = {}

local WALL_COLOR = Color3.fromRGB(96, 92, 108)
local FLOOR_COLOR = Color3.fromRGB(58, 54, 66)
local EXIT_COLOR = Color3.fromRGB(70, 255, 130)
local ENTRANCE_COLOR = Color3.fromRGB(80, 160, 255)

local function newPart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = position
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function label(parent: Part, text: string, color: Color3)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(120, 36)
	gui.StudsOffset = Vector3.new(0, 6, 0)
	gui.AlwaysOnTop = true
	gui.Parent = parent
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = color
	t.TextStrokeTransparency = 0
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.Parent = gui
end

local function pad(name: string, cx: number, cz: number, radius: number, color: Color3, parent: Instance): Part
	local p = newPart(name, Vector3.new(0.4, radius * 2, radius * 2), Vector3.new(cx, 0.2, cz), color, parent)
	p.Shape = Enum.PartType.Cylinder
	p.Orientation = Vector3.new(0, 0, 90)
	p.Material = Enum.Material.Neon
	p.CanCollide = false
	return p
end

-- Builds the maze area under `parent`. Returns the Model plus the wall count for validation.
function AreaBuilder.build(Maze: any, maze: any, layout: any, cfg: any, parent: Instance): Model
	local C, H, T = cfg.Maze.CellSize, cfg.Maze.WallHeight, cfg.Maze.WallThickness
	local model = Instance.new("Model")
	model.Name = "Area_Common"
	model.Parent = parent

	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = model

	newPart("Floor", Vector3.new(maze.width * C + T, cfg.Maze.FloorThickness, maze.height * C + T), Vector3.new(maze.width * C / 2, -cfg.Maze.FloorThickness / 2, maze.height * C / 2), FLOOR_COLOR, model)

	for y = 1, maze.height do
		for x = 1, maze.width do
			if not Maze.isOpen(maze, x, y, Maze.N) then
				newPart("Wall", Vector3.new(C + T, H, T), Vector3.new((x - 0.5) * C, H / 2, (y - 1) * C), WALL_COLOR, walls)
			end
			if not Maze.isOpen(maze, x, y, Maze.W) then
				newPart("Wall", Vector3.new(T, H, C + T), Vector3.new((x - 1) * C, H / 2, (y - 0.5) * C), WALL_COLOR, walls)
			end
			if y == maze.height then
				newPart("Wall", Vector3.new(C + T, H, T), Vector3.new((x - 0.5) * C, H / 2, y * C), WALL_COLOR, walls)
			end
			if x == maze.width then
				newPart("Wall", Vector3.new(T, H, C + T), Vector3.new(x * C, H / 2, (y - 0.5) * C), WALL_COLOR, walls)
			end
		end
	end

	local ex, ez = Maze.cellToWorld(layout.entrance.x, layout.entrance.y, C)
	local entrancePad = pad("Entrance", ex, ez, cfg.Escape.ZoneRadius, ENTRANCE_COLOR, model)
	label(entrancePad, "START", ENTRANCE_COLOR)

	for i, cell in layout.exits do
		local wx, wz = Maze.cellToWorld(cell.x, cell.y, C)
		local exitPad = pad("Exit" .. i, wx, wz, cfg.Escape.ZoneRadius, EXIT_COLOR, model)
		exitPad:SetAttribute("IsExit", true)
		label(exitPad, "EXIT", EXIT_COLOR)
		-- A tall faint beam so the exit can be spotted from over the walls.
		local beam = newPart("ExitBeam" .. i, Vector3.new(1.5, 70, 1.5), Vector3.new(wx, 35, wz), EXIT_COLOR, model)
		beam.Material = Enum.Material.Neon
		beam.Transparency = 0.55
		beam.CanCollide = false
	end

	return model
end

-- Lobby: a platform beside the maze with a pad to step on to enter, and the spawn point.
function AreaBuilder.buildLobby(cfg: any, parent: Instance): { spawn: Vector3, enterPad: Vector3 }
	local model = Instance.new("Model")
	model.Name = "Lobby"
	model.Parent = parent
	local centre = Vector3.new(-50, 0, 80)
	newPart("LobbyFloor", Vector3.new(60, 2, 60), centre + Vector3.new(0, -1, 0), Color3.fromRGB(70, 110, 80), model)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.Position = centre + Vector3.new(0, 0.5, 15)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Color = Color3.fromRGB(240, 240, 240)
	spawn.Parent = model

	local enterAt = centre + Vector3.new(0, 0, -12)
	local enterPad = pad("EnterCommon", enterAt.X, enterAt.Z, 6, Color3.fromRGB(255, 190, 60), model)
	label(enterPad, "ENTER COMMON AREA", Color3.fromRGB(255, 220, 120))
	return { spawn = spawn.Position + Vector3.new(0, 3, 0), enterPad = enterAt }
end

-- Sanity checks on the built area; returns a list of problems (empty = fine). Used by the in-Studio checks.
function AreaBuilder.validate(Maze: any, maze: any, layout: any, cfg: any, model: Model): { string }
	local problems: { string } = {}
	local C, H = cfg.Maze.CellSize, cfg.Maze.WallHeight
	local walls = model:FindFirstChild("Walls")
	if walls == nil then
		return { "no Walls folder" }
	end
	-- Expected wall count: closed N and W sides, plus the south and east borders.
	local expected = 0
	for y = 1, maze.height do
		for x = 1, maze.width do
			if not Maze.isOpen(maze, x, y, Maze.N) then
				expected += 1
			end
			if not Maze.isOpen(maze, x, y, Maze.W) then
				expected += 1
			end
			if y == maze.height then
				expected += 1
			end
			if x == maze.width then
				expected += 1
			end
		end
	end
	local actual = #walls:GetChildren()
	if actual ~= expected then
		table.insert(problems, string.format("wall count %d, expected %d", actual, expected))
	end
	local maxX, maxZ = maze.width * C + cfg.Maze.WallThickness, maze.height * C + cfg.Maze.WallThickness
	for _, w in walls:GetChildren() do
		local wp = w :: Part
		if not wp.Anchored then
			table.insert(problems, "unanchored wall")
		end
		if wp.Size.Y ~= H then
			table.insert(problems, "wall wrong height")
		end
		local p = wp.Position
		if p.X < -1 or p.X > maxX or p.Z < -1 or p.Z > maxZ then
			table.insert(problems, "wall outside the area")
		end
	end
	for i = 1, #layout.exits do
		if model:FindFirstChild("Exit" .. i) == nil then
			table.insert(problems, "missing Exit" .. i)
		end
	end
	if model:FindFirstChild("Floor") == nil then
		table.insert(problems, "missing floor")
	end
	return problems
end

return AreaBuilder
