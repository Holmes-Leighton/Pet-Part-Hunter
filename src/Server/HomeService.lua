--!strict
-- Home plots (spec section 2): every player gets a fixed plot with a starter room. The owner can buy furniture with
-- coins and place, move, rotate and delete it; visitors can only look. The rules live in Shared/House (unit tested);
-- this module builds the room and furniture in the world and connects them to remotes. The client only asks: the
-- server checks ownership, bounds, overlap and the item limit before anything is placed, and re-checks every request.
--
-- A plot is only reachable by teleport, and only the owner or someone the owner allowed may be teleported in.
-- Furniture is rebuilt from the saved layout when the owner's data loads and after every change.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local House = require(Shared:WaitForChild("House"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Analytics = require(script.Parent:WaitForChild("Analytics"))
local AntiExploit = require(script.Parent:WaitForChild("AntiExploit"))

local HomeService = {}

local H = Config.House
local CELL = H.CellSize
local ROOM_W, ROOM_D, ROOM_H = H.Width * CELL, H.Depth * CELL, H.WallRows * CELL

type Plot = { slot: number, ox: number, oz: number, model: Model, furniture: Folder }
local plots: { [Player]: Plot } = {}
local usedSlots: { [number]: boolean } = {}

local state = Instance.new("RemoteEvent")
state.Name = "HomeState"
state.Parent = ReplicatedStorage
local request = Instance.new("RemoteEvent")
request.Name = "HomeRequest"
request.Parent = ReplicatedStorage

local limiter = RateLimiter.new(Config.RateLimit.Home.perSecond, Config.RateLimit.Home.burst)
local inRunCheck: (Player) -> boolean = function()
	return false
end
local notifyRemote: RemoteEvent? = nil
local lobbySpawn = Vector3.new(0, 5, 0)

local function tell(player: Player, text: string)
	if notifyRemote then
		notifyRemote:FireClient(player, text)
	end
end

-- Building the room ---------------------------------------------------------------------------------------------
local function slab(parent: Instance, name: string, size: Vector3, centre: Vector3, color: Color3, ox: number, oz: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = Vector3.new(ox + centre.X, centre.Y, oz + centre.Z)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function buildRoom(player: Player, slot: number): Plot
	local col, row = (slot - 1) % H.PlotsPerRow, math.floor((slot - 1) / H.PlotsPerRow)
	local ox, oz = H.PlotOrigin.x + col * H.PlotSpacing, H.PlotOrigin.z + row * H.PlotSpacing
	local model = Instance.new("Model")
	model.Name = "Plot_" .. player.UserId
	model:SetAttribute("OwnerUserId", player.UserId)

	local t = H.WallThickness
	local wallColor = Color3.fromRGB(235, 225, 205)
	slab(model, "Floor", Vector3.new(ROOM_W + t, 1, ROOM_D + t), Vector3.new(ROOM_W / 2, -0.5, ROOM_D / 2), Color3.fromRGB(150, 110, 80), ox, oz)
	local ceiling = slab(model, "Ceiling", Vector3.new(ROOM_W + t, 0.5, ROOM_D + t), Vector3.new(ROOM_W / 2, ROOM_H + 0.25, ROOM_D / 2), Color3.fromRGB(245, 240, 230), ox, oz)
	ceiling.Transparency = 0.6 -- see-through so the camera can look in from above while building
	ceiling.CanQuery = false -- clicks go through it to the floor and walls

	local function wall(name: string, side: number, size: Vector3, centre: Vector3)
		local w = slab(model, name, size, centre, wallColor, ox, oz)
		w:SetAttribute("Side", side)
		return w
	end
	wall("WallN", 0, Vector3.new(ROOM_W + t, ROOM_H, t), Vector3.new(ROOM_W / 2, ROOM_H / 2, 0))
	wall("WallE", 1, Vector3.new(t, ROOM_H, ROOM_D + t), Vector3.new(ROOM_W, ROOM_H / 2, ROOM_D / 2))
	wall("WallW", 3, Vector3.new(t, ROOM_H, ROOM_D + t), Vector3.new(0, ROOM_H / 2, ROOM_D / 2))
	-- South wall (side 2) with the door gap: a piece each side of the door and a lintel over it.
	local door = H.Door
	local gapStart, gapEnd = door.start * CELL, (door.start + door.width) * CELL
	wall("WallS_Left", 2, Vector3.new(gapStart + t / 2, ROOM_H, t), Vector3.new((gapStart - t / 2) / 2, ROOM_H / 2, ROOM_D))
	wall("WallS_Right", 2, Vector3.new(ROOM_W + t / 2 - gapEnd, ROOM_H, t), Vector3.new((gapEnd + ROOM_W + t / 2) / 2, ROOM_H / 2, ROOM_D))
	local doorTop = door.rows * CELL
	local lintel = wall("WallS_Lintel", 2, Vector3.new(gapEnd - gapStart, ROOM_H - doorTop, t), Vector3.new((gapStart + gapEnd) / 2, doorTop + (ROOM_H - doorTop) / 2, ROOM_D))

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 40)
	gui.StudsOffset = Vector3.new(0, 0, 3)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 80
	gui.Parent = lintel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = player.DisplayName .. "'s House"
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = gui

	local furniture = Instance.new("Folder")
	furniture.Name = "Furniture"
	furniture.Parent = model
	model.Parent = workspace:FindFirstChild("Homes") or (function()
		local f = Instance.new("Folder")
		f.Name = "Homes"
		f.Parent = workspace
		return f
	end)()
	return { slot = slot, ox = ox, oz = oz, model = model, furniture = furniture }
end

local function variantColor(def: any, c: number): Color3
	local base = Color3.fromRGB(def.color[1], def.color[2], def.color[3])
	if c == 0 then
		return base
	end
	local h, s, v = base:ToHSV()
	return Color3.fromHSV((h + c * 0.22) % 1, math.max(s, 0.45), v)
end

local function buildItem(plot: Plot, item: House.Item)
	local def = House.def(Config, item.id)
	if def == nil then
		return
	end
	local cx, cy, cz, sx, sy, sz = House.worldBox(Config, def, item)
	local p = slab(plot.furniture, "Item_" .. item.uid, Vector3.new(sx, sy, sz), Vector3.new(cx, cy, cz), variantColor(def, item.c), plot.ox, plot.oz)
	p.Material = if def.premium then Enum.Material.Neon else Enum.Material.SmoothPlastic
	p.CanCollide = def.surface == "floor"
	p:SetAttribute("Uid", item.uid)
	p:SetAttribute("ItemId", item.id)
	if def.surface ~= "wall" then
		-- A darker stripe on the front so a turn is visible even on square items.
		local fx, fz = House.facing(item.r)
		local stripe = Instance.new("Part")
		stripe.Name = "Front"
		stripe.Anchored = true
		stripe.CanCollide = false
		stripe.CanQuery = false
		stripe.Size = Vector3.new(if fx ~= 0 then 0.3 else sx * 0.8, sy * 0.4, if fz ~= 0 then 0.3 else sz * 0.8)
		stripe.Position = p.Position + Vector3.new(fx * (sx / 2 - 0.05), 0, fz * (sz / 2 - 0.05))
		stripe.Color = Color3.new(0.1, 0.1, 0.1)
		stripe.Parent = plot.furniture
		stripe:SetAttribute("Uid", item.uid)
	end
end

local function rebuildFurniture(player: Player)
	local plot, data = plots[player], PlayerData.get(player)
	if plot == nil or data == nil then
		return
	end
	plot.furniture:ClearAllChildren()
	for _, item in data.house.items do
		buildItem(plot, item)
	end
end

-- State for the client ------------------------------------------------------------------------------------------
function HomeService.push(player: Player)
	local data, plot = PlayerData.get(player), plots[player]
	if data == nil or plot == nil then
		return
	end
	local items = {}
	for _, it in data.house.items do
		table.insert(items, { uid = it.uid, id = it.id, x = it.x, y = it.y, r = it.r, c = it.c })
	end
	-- Houses this player may visit: other players who have allowed them in.
	local visitable = {}
	for other in plots do
		local otherData = PlayerData.get(other)
		if other ~= player and otherData and table.find(otherData.house.allow, player.UserId) then
			table.insert(visitable, { userId = other.UserId, name = other.DisplayName })
		end
	end
	state:FireClient(player, {
		visitable = visitable,
		coins = data.coins,
		furniture = data.furniture,
		items = items,
		limit = House.limit(Config, data),
		allow = data.house.allow,
		ox = plot.ox,
		oz = plot.oz,
	})
end

-- Rebuilds a player's furniture from their data and resends their home state (used after an admin rollback).
function HomeService.refresh(player: Player)
	rebuildFurniture(player)
	HomeService.push(player)
end

-- Moving around ---------------------------------------------------------------------------------------------------
local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function insidePlot(plot: Plot, pos: Vector3): boolean
	return pos.X >= plot.ox - 3 and pos.X <= plot.ox + ROOM_W + 3 and pos.Z >= plot.oz - 3 and pos.Z <= plot.oz + ROOM_D + 3 and pos.Y > -5 and pos.Y < ROOM_H + 20
end

local function teleportInto(player: Player, plot: Plot)
	local char = player.Character
	if char then
		AntiExploit.expect(player)
		local door = H.Door
		char:PivotTo(CFrame.new(plot.ox + (door.start + door.width / 2) * CELL, 3.5, plot.oz + ROOM_D - (door.clearance + 1) * CELL))
	end
end

local function ownsHere(player: Player): Plot?
	local plot, root = plots[player], rootOf(player)
	if plot and root and insidePlot(plot, root.Position) then
		return plot
	end
	return nil
end

-- Requests ----------------------------------------------------------------------------------------------------------
function HomeService.start(inRun: (Player) -> boolean, notify: RemoteEvent, lobby: Vector3)
	inRunCheck = inRun
	notifyRemote = notify
	lobbySpawn = lobby

	local function onPlayer(player: Player)
		for slot = 1, H.PlotCount do
			if not usedSlots[slot] then
				usedSlots[slot] = true
				plots[player] = buildRoom(player, slot)
				-- Public so every client can place this player's pets in their room.
				player:SetAttribute("PlotX", plots[player].ox)
				player:SetAttribute("PlotZ", plots[player].oz)
				return
			end
		end
		warn("[PetPartHunter] no free home plot for " .. player.Name)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end

	PlayerData.onLoaded(function(player)
		rebuildFurniture(player)
		HomeService.push(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		limiter:forget(player)
		local plot = plots[player]
		if plot then
			-- Anyone still inside goes back to the lobby before the room disappears.
			for _, other in Players:GetPlayers() do
				local root = rootOf(other)
				if other ~= player and root and insidePlot(plot, root.Position) and other.Character then
					other.Character:PivotTo(CFrame.new(lobbySpawn))
				end
			end
			plot.model:Destroy()
			usedSlots[plot.slot] = nil
			plots[player] = nil
		end
	end)

	request.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any, c: any, d: any, e: any)
		local data, plot = PlayerData.get(player), plots[player]
		if data == nil or plot == nil or type(action) ~= "string" or not limiter:allow(player, os.clock()) then
			return
		end
		if action == "Sync" then
			HomeService.push(player)
			return
		end
		if inRunCheck(player) then
			tell(player, "Finish your run first!")
			return
		end

		-- Travel
		if action == "Home" then
			teleportInto(player, plot)
			return
		elseif action == "Lobby" then
			if player.Character then
				AntiExploit.expect(player)
				player.Character:PivotTo(CFrame.new(lobbySpawn))
			end
			return
		elseif action == "Visit" then
			local owner = if type(a) == "number" then Players:GetPlayerByUserId(a) else nil
			local ownerData = owner and PlayerData.get(owner)
			local ownerPlot = owner and plots[owner]
			if owner and ownerData and ownerPlot and House.canVisit(owner.UserId, ownerData.house, player.UserId) then
				teleportInto(player, ownerPlot)
			else
				tell(player, "You are not allowed in that house.")
			end
			return
		end

		-- Everything below changes the player's own house, so they must be standing in it.
		if ownsHere(player) == nil then
			tell(player, "Go home to do that.")
			return
		end
		local ok, why = true, "ok"
		if action == "Buy" then
			ok, why = House.buy(Config, data, a)
			if ok then
				Analytics.log(player, "BuyFurniture", 1, { item = tostring(a) })
			end
		elseif action == "Place" then
			local item
			item, why = House.place(Config, data, a, b, c, d, e)
			ok = item ~= nil
		elseif action == "Move" then
			ok, why = House.move(Config, data, a, b, c, d, e)
		elseif action == "Remove" then
			ok, why = House.remove(Config, data, a)
		elseif action == "Allow" then
			ok, why = House.setAllowed(Config, data, a, b)
		else
			return
		end
		if not ok then
			tell(player, "Cannot do that: " .. why)
		end
		if action ~= "Allow" then
			rebuildFurniture(player)
		end
		HomeService.push(player)
		if action == "Allow" then
			-- Everyone's "houses you can visit" list may have changed.
			for _, other in Players:GetPlayers() do
				if other ~= player then
					HomeService.push(other)
				end
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		for player, plot in plots do
			local root = rootOf(player)
			local at = root ~= nil and insidePlot(plot, root.Position)
			if player:GetAttribute("InHome") ~= at then
				player:SetAttribute("InHome", at)
			end
		end
	end)
end

return HomeService
