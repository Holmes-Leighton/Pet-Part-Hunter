--!strict
-- Pets living in your house (spec section 2): your equipped pets wander around your room as a display. Animation is
-- client-only, as the spec asks: the server only stores which parts a pet has (InventoryState) and this script builds
-- and moves placeholder models from that. Real pets will use the shared rig and part meshes (spec section 6).
-- Only your own equipped pets are shown, and only while you are in your own house, so nothing animates elsewhere.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local inventoryRemote = ReplicatedStorage:WaitForChild("InventoryState") :: RemoteEvent
local homeRemote = ReplicatedStorage:WaitForChild("HomeState") :: RemoteEvent

local player = Players.LocalPlayer
local H = Config.House
local ROOM_W, ROOM_D = H.Width * H.CellSize, H.Depth * H.CellSize
local MARGIN = 4 -- studs kept between pets and the walls
local SPEED = 4 -- studs per second
local MAX_PETS = 6 -- the most equipped at once (spec); bounds the animation work

local inv: any = nil
local plotX: number? = nil
local plotZ: number? = nil

type Walker = { model: Model, x: number, z: number, tx: number, tz: number, wait: number, phase: number }
local walkers: { Walker } = {}
local folder = Instance.new("Folder")
folder.Name = "HomePets"
folder.Parent = workspace

-- A stable colour per species for the placeholder blocks.
local function colorOf(partId: string): Color3
	local species = string.match(partId, "^(.-)_") or partId
	local h = 0
	for i = 1, #species do
		h = (h * 31 + string.byte(species, i)) % 360
	end
	return Color3.fromHSV(h / 360, 0.6, 1)
end

-- Block sizes and offsets per socket, relative to the body: a stand-in for the six sockets of the shared rig.
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
	model.Name = "Pet_" .. pet.uid
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.Parent = model
	model.PrimaryPart = root
	for socket, item in pet.slots do
		local l = LAYOUT[socket]
		if l then
			local block = Instance.new("Part")
			block.Name = socket
			block.Size = l.size
			block.Color = colorOf(item.id)
			block.Material = Enum.Material.SmoothPlastic
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
	return model
end

local function clearWalkers()
	for _, w in walkers do
		w.model:Destroy()
	end
	table.clear(walkers)
end

local function inOwnHome(): boolean
	return player:GetAttribute("InHome") == true and player:GetAttribute("RunState") ~= "running" and plotX ~= nil
end

local function randomSpot(): (number, number)
	return MARGIN + math.random() * (ROOM_W - 2 * MARGIN), MARGIN + math.random() * (ROOM_D - 2 * MARGIN)
end

-- Only rebuild when the set of shown pets really changed, so placing furniture does not make pets jump.
local shown = ""

local function rebuild()
	local key = ""
	if inv ~= nil and inOwnHome() then
		key = table.concat(inv.equipped, ",")
		for _, pet in inv.pets do
			if table.find(inv.equipped, pet.uid) then
				for socket, item in pet.slots do
					key ..= pet.uid .. socket .. item.id .. ";"
				end
			end
		end
		key ..= "home"
	end
	if key == shown then
		return
	end
	shown = key
	clearWalkers()
	if key == "" then
		return
	end
	local byUid: { [number]: any } = {}
	for _, pet in inv.pets do
		byUid[pet.uid] = pet
	end
	for _, uid in inv.equipped do
		local pet = byUid[uid]
		if pet and #walkers < MAX_PETS then
			local x, z = randomSpot()
			local model = buildModel(pet)
			model.Parent = folder
			table.insert(walkers, { model = model, x = x, z = z, tx = x, tz = z, wait = math.random() * 2, phase = math.random() * 6 })
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	if #walkers == 0 or plotX == nil or plotZ == nil then
		return
	end
	local t = os.clock()
	for _, w in walkers do
		if w.wait > 0 then
			w.wait -= dt
			if w.wait <= 0 then
				w.tx, w.tz = randomSpot()
			end
		else
			local dx, dz = w.tx - w.x, w.tz - w.z
			local dist = math.sqrt(dx * dx + dz * dz)
			if dist < 0.3 then
				w.wait = 1 + math.random() * 3
			else
				local step = math.min(SPEED * dt, dist)
				w.x += dx / dist * step
				w.z += dz / dist * step
			end
		end
		local bob = if w.wait > 0 then 0 else math.abs(math.sin(t * 8 + w.phase)) * 0.25
		local pos = Vector3.new(plotX + w.x, bob, plotZ + w.z)
		local facing = Vector3.new(w.tx - w.x, 0, w.tz - w.z)
		local look = if facing.Magnitude > 0.1 then pos + facing.Unit else pos + Vector3.new(0, 0, 1)
		-- The blocks are built facing -Z (head at -2), so look away from the target to face it.
		w.model:PivotTo(CFrame.lookAt(pos, look) * CFrame.Angles(0, math.pi, 0))
	end
end)

inventoryRemote.OnClientEvent:Connect(function(snapshot: any)
	inv = snapshot
	rebuild()
end)
homeRemote.OnClientEvent:Connect(function(snapshot: any)
	plotX, plotZ = snapshot.ox, snapshot.oz
	rebuild()
end)
for _, name in { "InHome", "RunState" } do
	player:GetAttributeChangedSignal(name):Connect(rebuild)
end
