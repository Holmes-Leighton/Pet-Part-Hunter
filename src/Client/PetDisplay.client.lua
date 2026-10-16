--!strict
-- Everyone sees everyone's pets (a status symbol that keeps players aiming higher). Each player's equipped pets are
-- published by the server as the player attribute "PetsEquipped" (part ids and tiers only); this script builds and
-- animates placeholder models for every player in range:
--   * in the lobby and around the world the pets trail behind their owner,
--   * in the owner's house (attribute InHome) they wander around the room,
--   * while the owner is in an area run they are hidden (Config.PetDisplay.HideDuringRuns).
-- Animation is client-only, as the spec asks, and limited by distance and a model cap so phones stay smooth.
-- Real pets will use the shared rig and part meshes (spec section 6); these blocks stand in until then.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Parts = require(Shared:WaitForChild("Parts"))

local localPlayer = Players.LocalPlayer
local D = Config.PetDisplay
local H = Config.House
local ROOM_W, ROOM_D = H.Width * H.CellSize, H.Depth * H.CellSize
local MARGIN = 4
local WANDER_SPEED = 4

type Walker = {
	model: Model,
	x: number, -- world position of the pet
	z: number,
	tx: number, -- wander target (in room coordinates)
	tz: number,
	wait: number,
	phase: number,
	slotIndex: number, -- position in the owner's line of pets
}
type Entry = { signature: string, pets: { any }, walkers: { Walker } }

local entries: { [Player]: Entry } = {}
local liveModels = 0
local folder = Instance.new("Folder")
folder.Name = "PetDisplay"
folder.Parent = workspace

local RARITY_COLORS = {
	Color3.fromRGB(235, 235, 235),
	Color3.fromRGB(110, 220, 110),
	Color3.fromRGB(90, 170, 255),
	Color3.fromRGB(190, 110, 255),
	Color3.fromRGB(255, 170, 50),
	Color3.fromRGB(255, 70, 110),
}

local function rarityIndex(partId: string): number
	local def = Parts.get(partId)
	if def then
		for i, area in Config.Areas do
			if area.name == def.rarity then
				return i
			end
		end
	end
	return 1
end

local function colorOf(partId: string): Color3
	local species = string.match(partId, "^(.-)_") or partId
	local h = 0
	for i = 1, #species do
		h = (h * 31 + string.byte(species, i)) % 360
	end
	return Color3.fromHSV(h / 360, 0.6, 1)
end

-- Block sizes and offsets per socket, a stand-in for the six sockets of the shared pet rig.
local LAYOUT = {
	Body = { size = Vector3.new(2.2, 1.8, 3), offset = Vector3.new(0, 1.8, 0) },
	Head = { size = Vector3.new(1.6, 1.6, 1.6), offset = Vector3.new(0, 3, -2) },
	Legs = { size = Vector3.new(2, 1, 2.6), offset = Vector3.new(0, 0.5, 0) },
	Tail = { size = Vector3.new(0.6, 0.6, 1.6), offset = Vector3.new(0, 2.2, 2.2) },
	Special1 = { size = Vector3.new(0.4, 1.4, 1.4), offset = Vector3.new(-1.5, 2.8, 0) },
	Special2 = { size = Vector3.new(0.4, 1.4, 1.4), offset = Vector3.new(1.5, 2.8, 0) },
}

local function buildModel(pet: any): Model
	local model = Instance.new("Model")
	model.Name = "Pet_" .. tostring(pet.uid)
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.Parent = model
	model.PrimaryPart = root

	local best = 1
	for _, item in pet.slots do
		best = math.max(best, rarityIndex(item.id))
	end
	for socket, item in pet.slots do
		local l = LAYOUT[socket]
		if l then
			local block = Instance.new("Part")
			block.Name = socket
			block.Size = l.size
			block.Color = colorOf(item.id)
			-- Higher tiers glow, so a good pet is obvious from across the lobby.
			block.Material = if best >= 5 or item.tier >= 3 then Enum.Material.Neon else Enum.Material.SmoothPlastic
			block.Anchored = false
			block.CanCollide = false
			block.CanQuery = false
			block.CanTouch = false
			block.Massless = true
			block.CFrame = root.CFrame * CFrame.new(l.offset)
			local weld = Instance.new("WeldConstraint")
			weld.Part0, weld.Part1 = root, block
			weld.Parent = block
			block.Parent = model
		end
	end
	if best >= D.TagFromRarity then
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(110, 26)
		gui.StudsOffset = Vector3.new(0, 6, 0)
		gui.AlwaysOnTop = false
		gui.MaxDistance = 70
		gui.Parent = root
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = string.upper(Config.Areas[best].name)
		label.TextColor3 = RARITY_COLORS[best] or RARITY_COLORS[1]
		label.TextStrokeTransparency = 0
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.Parent = gui
	end
	return model
end

local function clear(entry: Entry)
	for _, w in entry.walkers do
		w.model:Destroy()
		liveModels -= 1
	end
	table.clear(entry.walkers)
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function focusPoint(): Vector3
	local mine = rootOf(localPlayer)
	if mine then
		return mine.Position
	end
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function hidden(player: Player): boolean
	return D.HideDuringRuns and player:GetAttribute("RunState") == "running"
end

-- Reads a player's PetsEquipped attribute into their entry (cheap: only when it changes).
local function refresh(player: Player)
	local json = player:GetAttribute("PetsEquipped")
	local entry = entries[player]
	if entry == nil then
		entry = { signature = "", pets = {}, walkers = {} }
		entries[player] = entry
	end
	if type(json) ~= "string" or json == entry.signature then
		return
	end
	entry.signature = json
	clear(entry)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	entry.pets = if ok and type(decoded) == "table" then decoded else {}
end

-- Builds the models for a player when they come into range (and removes them when they leave it).
local function ensureBuilt(player: Player, entry: Entry)
	if #entry.walkers == #entry.pets then
		return
	end
	clear(entry)
	for i, pet in entry.pets do
		if liveModels >= D.MaxModels then
			break
		end
		local model = buildModel(pet)
		model.Parent = folder
		liveModels += 1
		local rx, rz = MARGIN + math.random() * (ROOM_W - 2 * MARGIN), MARGIN + math.random() * (ROOM_D - 2 * MARGIN)
		table.insert(entry.walkers, { model = model, x = 0, z = 0, tx = rx, tz = rz, wait = math.random() * 2, phase = math.random() * 6, slotIndex = i })
	end
end

local function faceAndPlace(w: Walker, pos: Vector3, toward: Vector3)
	local dir = Vector3.new(toward.X - pos.X, 0, toward.Z - pos.Z)
	local look = if dir.Magnitude > 0.1 then pos + dir.Unit else pos + Vector3.new(0, 0, 1)
	-- Models are built facing -Z (head at -2); lookAt faces +Z... so turn half a circle.
	w.model:PivotTo(CFrame.lookAt(pos, look) * CFrame.Angles(0, math.pi, 0))
end

RunService.Heartbeat:Connect(function(dt)
	local focus = focusPoint()
	local t = os.clock()
	for player, entry in entries do
		local root = rootOf(player)
		if #entry.pets == 0 or root == nil or hidden(player) or (root.Position - focus).Magnitude > D.ShowDistance then
			if #entry.walkers > 0 then
				clear(entry)
			end
			continue
		end
		ensureBuilt(player, entry)

		local plotX, plotZ = player:GetAttribute("PlotX"), player:GetAttribute("PlotZ")
		local atHome = player:GetAttribute("InHome") == true and type(plotX) == "number" and type(plotZ) == "number"
		for _, w in entry.walkers do
			if atHome then
				-- Wander around the owner's room.
				local px, pz = plotX :: number, plotZ :: number
				if w.x == 0 and w.z == 0 then
					w.x, w.z = px + w.tx, pz + w.tz
				end
				if w.wait > 0 then
					w.wait -= dt
					if w.wait <= 0 then
						w.tx = MARGIN + math.random() * (ROOM_W - 2 * MARGIN)
						w.tz = MARGIN + math.random() * (ROOM_D - 2 * MARGIN)
					end
				else
					local dx, dz = px + w.tx - w.x, pz + w.tz - w.z
					local dist = math.sqrt(dx * dx + dz * dz)
					if dist < 0.3 then
						w.wait = 1 + math.random() * 3
					else
						local step = math.min(WANDER_SPEED * dt, dist)
						w.x += dx / dist * step
						w.z += dz / dist * step
					end
				end
				local bob = if w.wait > 0 then 0 else math.abs(math.sin(t * 8 + w.phase)) * 0.25
				faceAndPlace(w, Vector3.new(w.x, bob, w.z), Vector3.new(px + w.tx, 0, pz + w.tz))
			else
				-- Trail behind the owner in a loose double line.
				local cf = root.CFrame
				local row = math.floor((w.slotIndex - 1) / 2)
				local side = if w.slotIndex % 2 == 1 then -2.5 else 2.5
				local target = (cf * CFrame.new(side, 0, 4 + row * 3.5)).Position
				if w.x == 0 and w.z == 0 then
					w.x, w.z = target.X, target.Z
				end
				local k = 1 - math.exp(-6 * dt) -- smooth follow, independent of frame rate
				local nx, nz = w.x + (target.X - w.x) * k, w.z + (target.Z - w.z) * k
				local moved = math.sqrt((nx - w.x) ^ 2 + (nz - w.z) ^ 2) / math.max(dt, 1e-3)
				w.x, w.z = nx, nz
				local ground = root.Position.Y - 2.9
				local bob = if moved > 1 then math.abs(math.sin(t * 8 + w.phase)) * 0.3 else 0
				local pos = Vector3.new(w.x, ground + bob, w.z)
				faceAndPlace(w, pos, pos + root.CFrame.LookVector) -- face the way the owner is heading
			end
		end
	end
end)

local function track(player: Player)
	refresh(player)
	player:GetAttributeChangedSignal("PetsEquipped"):Connect(function()
		refresh(player)
	end)
end

Players.PlayerAdded:Connect(track)
for _, p in Players:GetPlayers() do
	track(p)
end
Players.PlayerRemoving:Connect(function(player)
	local entry = entries[player]
	if entry then
		clear(entry)
		entries[player] = nil
	end
end)
