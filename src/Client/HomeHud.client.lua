--!strict
-- Home UI (spec section 2): go home / back to the lobby, and in your own house a build mode with a shop, your stock
-- and visitors. Placing uses a ghost preview that is green when the spot is valid and red when it is not, using the
-- same House.canPlace the server uses. Tap or click the floor or a wall to aim the ghost, then use the big buttons:
-- no drag and drop, so it works on phones. Tap a placed item to select it, then move, rotate, recolour or delete it.
-- The client only asks; the server re-checks everything and sends back the result.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local House = require(Shared:WaitForChild("House"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local request = ReplicatedStorage:WaitForChild("HomeRequest") :: RemoteEvent
local stateRemote = ReplicatedStorage:WaitForChild("HomeState") :: RemoteEvent

local player = Players.LocalPlayer
local H = Config.House
local CELL = H.CellSize

local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterHomeHud"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local GREEN, RED = Color3.fromRGB(60, 150, 80), Color3.fromRGB(200, 60, 60)

-- State -----------------------------------------------------------------------------------------------------------
local inv: any = nil -- latest HomeState snapshot
local building = false
local mode = "idle" -- idle | placing | moving
local placingId: string? = nil -- furniture id being placed
local selectedUid: number? = nil -- placed item selected (idle) or being moved (moving)
local aim = { x = 0, y = 0, r = 0, c = 0 } -- where the ghost is
local aimOk = false
local tab = "Shop"

local ghost = Instance.new("Part")
ghost.Name = "PlacementGhost"
ghost.Anchored = true
ghost.CanCollide = false
ghost.CanQuery = false
ghost.CanTouch = false
ghost.Transparency = 1
ghost.Material = Enum.Material.Neon
ghost.Parent = workspace

local selectionBox = Instance.new("SelectionBox")
selectionBox.Color3 = Color3.fromRGB(255, 220, 80)
selectionBox.LineThickness = 0.08
selectionBox.Parent = gui

-- Buttons that are always there ---------------------------------------------------------------------------------
local travelButton = UiKit.button(gui, "HOME", UDim2.fromOffset(110, 64), Color3.fromRGB(70, 130, 210))
travelButton.AnchorPoint = Vector2.new(0, 0.5)
travelButton.Position = UDim2.new(0.03, 0, 0.5, 190)
local buildButton = UiKit.button(gui, "BUILD", UDim2.fromOffset(110, 64), Color3.fromRGB(230, 130, 40))
buildButton.AnchorPoint = Vector2.new(0, 0.5)
buildButton.Position = UDim2.new(0.03, 0, 0.5, 262)

-- Build sheet (bottom) -----------------------------------------------------------------------------------------
local sheet = Instance.new("Frame")
sheet.Name = "BuildSheet"
sheet.AnchorPoint = Vector2.new(0.5, 1)
sheet.Position = UDim2.fromScale(0.5, 0.99)
sheet.Size = UDim2.fromScale(0.74, 0.36)
sheet.BackgroundColor3 = Color3.fromRGB(70, 48, 34)
sheet.Visible = false
sheet.Parent = gui
UiKit.round(sheet, 14)
UiKit.outline(sheet, 3)

local tabRow = Instance.new("Frame")
tabRow.BackgroundTransparency = 1
tabRow.Position = UDim2.fromOffset(8, 6)
tabRow.Size = UDim2.new(1, -64, 0, 38)
tabRow.Parent = sheet
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabRow
local closeButton = UiKit.button(sheet, "X", UDim2.fromOffset(40, 38), Color3.fromRGB(220, 50, 50))
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -8, 0, 6)

local list = UiKit.list(sheet, UDim2.fromOffset(8, 50), UDim2.new(1, -16, 1, -92))
local footer = UiKit.label(sheet, "", UDim2.new(1, -16, 0, 30))
footer.AnchorPoint = Vector2.new(0, 1)
footer.Position = UDim2.new(0, 8, 1, -6)

-- Action bar (top centre): shown while placing or when an item is selected.
local actions = Instance.new("Frame")
actions.Name = "Actions"
actions.AnchorPoint = Vector2.new(0.5, 0)
actions.Position = UDim2.fromScale(0.5, 0.1)
actions.Size = UDim2.fromOffset(440, 56)
actions.BackgroundTransparency = 1
actions.Visible = false
actions.Parent = gui
local actionLayout = Instance.new("UIListLayout")
actionLayout.FillDirection = Enum.FillDirection.Horizontal
actionLayout.Padding = UDim.new(0, 8)
actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
actionLayout.Parent = actions
local function actionButton(text: string, color: Color3): TextButton
	return UiKit.button(actions, text, UDim2.fromOffset(100, 54), color)
end
local rotateBtn = actionButton("ROTATE", Color3.fromRGB(70, 130, 210))
local colourBtn = actionButton("COLOUR", Color3.fromRGB(170, 90, 200))
local okBtn = actionButton("PLACE", GREEN)
local moveBtn = actionButton("MOVE", Color3.fromRGB(230, 130, 40))
local deleteBtn = actionButton("DELETE", RED)
local cancelBtn = actionButton("CANCEL", Color3.fromRGB(100, 100, 110))

local hint = UiKit.label(gui, "", UDim2.fromOffset(440, 28))
hint.AnchorPoint = Vector2.new(0.5, 0)
hint.Position = UDim2.fromScale(0.5, 0.1)
hint.Position = UDim2.new(0.5, 0, 0.1, 62)
hint.TextXAlignment = Enum.TextXAlignment.Center
hint.TextColor3 = Color3.fromRGB(255, 230, 150)

-- Helpers ------------------------------------------------------------------------------------------------------------
local function def(id: string): any
	return House.def(Config, id)
end

local function itemByUid(uid: number): any?
	for _, it in inv.items do
		if it.uid == uid then
			return it
		end
	end
	return nil
end

local function plotOrigin(): Vector3
	return Vector3.new(inv.ox, 0, inv.oz)
end

local function itemPart(uid: number): BasePart?
	local homes = workspace:FindFirstChild("Homes")
	local plot = homes and homes:FindFirstChild("Plot_" .. player.UserId)
	local furniture = plot and plot:FindFirstChild("Furniture")
	return furniture and furniture:FindFirstChild("Item_" .. uid) :: BasePart?
end

local function inHome(): boolean
	return player:GetAttribute("InHome") == true and player:GetAttribute("RunState") ~= "running"
end

-- Ghost and aiming ----------------------------------------------------------------------------------------------
local function activeDef(): any?
	if mode == "placing" and placingId then
		return def(placingId)
	elseif mode == "moving" and selectedUid then
		local it = itemByUid(selectedUid)
		return it and def(it.id)
	end
	return nil
end

local function updateGhost()
	local d = activeDef()
	if d == nil or inv == nil then
		ghost.Transparency = 1
		return
	end
	local cx, cy, cz, sx, sy, sz = House.worldBox(Config, d, aim)
	ghost.Size = Vector3.new(sx, sy, sz)
	ghost.Position = plotOrigin() + Vector3.new(cx, cy, cz)
	local limit = if mode == "placing" then inv.limit else nil
	local ok = House.canPlace(Config, inv.items, d, aim.x, aim.y, aim.r, if mode == "moving" then selectedUid else nil, limit)
	aimOk = ok
	ghost.Color = if ok then Color3.fromRGB(90, 255, 120) else Color3.fromRGB(255, 70, 70)
	ghost.Transparency = 0.45
end

-- Turns a point the player aimed at (in plot coordinates) into a grid position for the item being placed.
local function aimAt(localPos: Vector3, hit: Instance?)
	local d = activeDef()
	if d == nil then
		return
	end
	if d.surface == "wall" then
		local side = if hit then hit:GetAttribute("Side") else nil
		if type(side) ~= "number" then
			-- Aimed at the floor or furniture: use the nearest wall.
			local dists = { localPos.Z, H.Width * CELL - localPos.X, H.Depth * CELL - localPos.Z, localPos.X }
			side = 0
			for i = 1, 3 do
				if dists[i + 1] < dists[(side :: number) + 1] then
					side = i
				end
			end
		end
		aim.r = side :: number
		local along = if aim.r % 2 == 0 then localPos.X else localPos.Z
		aim.x = math.floor(along / CELL - d.w / 2 + 0.5)
		aim.y = if localPos.Y < 1 then 1 else math.max(0, math.floor(localPos.Y / CELL - d.d / 2 + 0.5))
	else
		local w, dd = House.dims(d, aim.r)
		aim.x = math.floor(localPos.X / CELL - w / 2 + 0.5)
		aim.y = math.floor(localPos.Z / CELL - dd / 2 + 0.5)
	end
	updateGhost()
end

local function pointerRay(position: Vector3): RaycastResult?
	local camera = workspace.CurrentCamera
	if camera == nil then
		return nil
	end
	local ray = camera:ScreenPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if player.Character then { player.Character, ghost } else { ghost }
	return workspace:Raycast(ray.Origin, ray.Direction * 400, params)
end

-- Rendering ---------------------------------------------------------------------------------------------------------
local render: () -> ()

local function setMode(newMode: string, id: string?, uid: number?)
	mode, placingId, selectedUid = newMode, id, uid
	local d = activeDef()
	if newMode == "placing" and d then
		aim.r, aim.c = if d.surface == "wall" then 0 else aim.r, 0
		aim.x, aim.y = 6, 6
		if d.surface == "wall" then
			aim.x, aim.y, aim.r = 4, 1, 0
		end
	elseif newMode == "moving" and uid then
		local it = itemByUid(uid)
		if it then
			aim.x, aim.y, aim.r, aim.c = it.x, it.y, it.r, it.c
		end
	end
	render()
	updateGhost()
end

local function renderActions()
	local selected = selectedUid and mode == "idle"
	local active = mode ~= "idle"
	actions.Visible = building and (active or selected == true)
	rotateBtn.Visible = active
	colourBtn.Visible = active
	okBtn.Visible = active
	okBtn.Text = if mode == "placing" then "PLACE" else "SAVE"
	cancelBtn.Visible = active
	moveBtn.Visible = selected == true
	deleteBtn.Visible = selected == true
	if mode == "placing" then
		hint.Text = if aimOk then "Tap a spot, then PLACE" else "Red = can't go there"
	elseif mode == "moving" then
		hint.Text = "Tap a new spot, then SAVE"
	elseif selected then
		hint.Text = "Selected: move, or delete to get it back"
	else
		hint.Text = if building then "Tap furniture to select it" else ""
	end
	hint.Visible = building

	selectionBox.Adornee = if selectedUid and mode ~= "placing" then itemPart(selectedUid) else nil
end

local TABS = { "Shop", "Stock", "Visitors" }
local tabButtons: { [string]: TextButton } = {}
for _, name in TABS do
	local b = UiKit.button(tabRow, string.upper(name), UDim2.new(1 / #TABS, -6, 1, 0), Color3.fromRGB(110, 80, 60))
	tabButtons[name] = b
	b.Activated:Connect(function()
		tab = name
		render()
	end)
end

local function renderList()
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for _, name in TABS do
		tabButtons[name].BackgroundColor3 = if name == tab then Color3.fromRGB(230, 130, 40) else Color3.fromRGB(110, 80, 60)
	end
	if tab == "Shop" then
		for _, f in Config.Furniture do
			if f.premium then
				UiKit.row(list, string.format("%s  (%dx%d)  Robux set", f.name, f.w, f.d), "R$ " .. f.robux, Color3.fromRGB(90, 90, 90), nil)
			else
				local canAfford = inv.coins >= f.coins
				UiKit.row(list, string.format("%s  (%dx%d, %s)", f.name, f.w, f.d, f.surface), f.coins .. " coins", if canAfford then GREEN else Color3.fromRGB(90, 90, 90), function()
					request:FireServer("Buy", f.id)
				end)
			end
		end
	elseif tab == "Stock" then
		local any = false
		for _, f in Config.Furniture do
			local n = inv.furniture[f.id] or 0
			if n > 0 then
				any = true
				UiKit.row(list, string.format("%s  x%d", f.name, n), "PLACE", GREEN, function()
					setMode("placing", f.id, nil)
				end)
			end
		end
		if not any then
			UiKit.row(list, "Nothing in stock. Buy furniture in the Shop!", nil)
		end
	else
		for _, other in Players:GetPlayers() do
			if other ~= player then
				local allowed = table.find(inv.allow, other.UserId) ~= nil
				UiKit.row(list, other.DisplayName .. (if allowed then "  (can visit)" else ""), if allowed then "REMOVE" else "ALLOW", if allowed then RED else GREEN, function()
					request:FireServer("Allow", other.UserId, not allowed)
				end)
			end
		end
		for _, v in inv.visitable do
			UiKit.row(list, "Visit " .. v.name .. "'s house", "VISIT", Color3.fromRGB(70, 130, 210), function()
				request:FireServer("Visit", v.userId)
			end)
		end
	end
	footer.Text = string.format("Coins %d    Items placed %d / %d", inv.coins, #inv.items, inv.limit)
end

function render()
	local home = inHome()
	travelButton.Text = if home then "LOBBY" else "HOME"
	buildButton.Visible = home and not building
	sheet.Visible = building and home and mode == "idle" and selectedUid == nil
	if inv and sheet.Visible then
		renderList()
	end
	if not home and building then
		building = false
		mode, placingId, selectedUid = "idle", nil, nil
	end
	ghost.Transparency = if building and mode ~= "idle" then ghost.Transparency else 1
	renderActions()
end

-- Input -------------------------------------------------------------------------------------------------------------
travelButton.Activated:Connect(function()
	request:FireServer(if inHome() then "Lobby" else "Home")
end)
buildButton.Activated:Connect(function()
	building = true
	tab = "Shop"
	render()
end)
closeButton.Activated:Connect(function()
	building = false
	setMode("idle", nil, nil)
end)
cancelBtn.Activated:Connect(function()
	setMode("idle", nil, nil)
end)
rotateBtn.Activated:Connect(function()
	aim.r = (aim.r + 1) % 4
	updateGhost()
	renderActions()
end)
colourBtn.Activated:Connect(function()
	aim.c = (aim.c + 1) % (H.Variants or 1)
	updateGhost()
end)
okBtn.Activated:Connect(function()
	if not aimOk then
		return
	end
	if mode == "placing" and placingId then
		request:FireServer("Place", placingId, aim.x, aim.y, aim.r, aim.c)
	elseif mode == "moving" and selectedUid then
		request:FireServer("Move", selectedUid, aim.x, aim.y, aim.r, aim.c)
		setMode("idle", nil, nil)
	end
end)
moveBtn.Activated:Connect(function()
	if selectedUid then
		setMode("moving", nil, selectedUid)
	end
end)
deleteBtn.Activated:Connect(function()
	if selectedUid then
		request:FireServer("Remove", selectedUid)
		setMode("idle", nil, nil)
	end
end)

local function onPointer(position: Vector3)
	if not building or inv == nil or not inHome() then
		return
	end
	local hit = pointerRay(position)
	if mode == "idle" then
		-- Select a placed item (or clear the selection).
		local uid = if hit then hit.Instance:GetAttribute("Uid") else nil
		selectedUid = if type(uid) == "number" then uid else nil
		render()
	elseif hit then
		aimAt(hit.Position - plotOrigin(), hit.Instance)
		renderActions()
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		onPointer(input.Position)
	end
end)
UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
	-- Mouse hover moves the ghost too, so desktop players see where it will land.
	if not processed and input.UserInputType == Enum.UserInputType.MouseMovement and mode ~= "idle" then
		onPointer(input.Position)
	end
end)

stateRemote.OnClientEvent:Connect(function(snapshot: any)
	inv = snapshot
	-- Out of stock after placing the last one: leave placing mode.
	if mode == "placing" and placingId and (inv.furniture[placingId] or 0) < 1 then
		mode, placingId = "idle", nil
	end
	if selectedUid and itemByUid(selectedUid) == nil then
		selectedUid = nil
	end
	render()
	updateGhost()
end)

for _, name in { "InHome", "RunState" } do
	player:GetAttributeChangedSignal(name):Connect(render)
end
Players.PlayerAdded:Connect(function()
	if building and tab == "Visitors" then
		render()
	end
end)
Players.PlayerRemoving:Connect(function()
	task.defer(function()
		if building and tab == "Visitors" then
			render()
		end
	end)
end)
request:FireServer("Sync")
render()
