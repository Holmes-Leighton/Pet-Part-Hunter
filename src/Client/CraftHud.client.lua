--!strict
-- Crafting station UI (spec section 5): Build a pet, Merge duplicates, Pets (equip), Index (Part Index).
-- It only draws the InventoryState snapshot the server pushes and sends requests; the server checks every rule.
-- Mobile-first: big touch targets, one scrolling list per tab, no drag and drop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Parts = require(Shared:WaitForChild("Parts"))
local request = ReplicatedStorage:WaitForChild("CraftRequest") :: RemoteEvent
local stateRemote = ReplicatedStorage:WaitForChild("InventoryState") :: RemoteEvent

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterCraftHud"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local DARK = Color3.fromRGB(20, 14, 10)

local function round(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function button(parent: Instance, text: string, size: UDim2, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Size = size
	b.BackgroundColor3 = color
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextStrokeTransparency = 0
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.Parent = parent
	round(b, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = DARK
	stroke.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
	pad.Parent = b
	return b
end

local function text(parent: Instance, str: string, height: number): TextLabel
	local t = Instance.new("TextLabel")
	t.Size = UDim2.new(1, 0, 0, height)
	t.BackgroundTransparency = 1
	t.Text = str
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.4
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Parent = parent
	return t
end

-- Opening button (lobby only) under the rebirth button.
local openButton = button(gui, "CRAFT", UDim2.fromOffset(110, 70), Color3.fromRGB(230, 130, 40))
openButton.AnchorPoint = Vector2.new(0, 0.5)
openButton.Position = UDim2.new(0.03, 0, 0.5, 100)

local panel = Instance.new("Frame")
panel.Name = "CraftPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.78, 0.8)
panel.BackgroundColor3 = Color3.fromRGB(70, 48, 34)
panel.Visible = false
panel.Parent = gui
round(panel, 16)
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 4
panelStroke.Color = DARK
panelStroke.Parent = panel

local title = text(panel, "CRAFTING STATION", 36)
title.Position = UDim2.fromOffset(16, 8)
title.Size = UDim2.new(1, -90, 0, 36)
local close = button(panel, "X", UDim2.fromOffset(44, 44), Color3.fromRGB(220, 50, 50))
close.AnchorPoint = Vector2.new(1, 0)
close.Position = UDim2.new(1, -10, 0, 8)

local tabRow = Instance.new("Frame")
tabRow.BackgroundTransparency = 1
tabRow.Position = UDim2.fromOffset(12, 56)
tabRow.Size = UDim2.new(1, -24, 0, 44)
tabRow.Parent = panel
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 8)
tabLayout.Parent = tabRow

local list = Instance.new("ScrollingFrame")
list.BackgroundColor3 = Color3.fromRGB(46, 30, 22)
list.Position = UDim2.fromOffset(12, 108)
list.Size = UDim2.new(1, -24, 1, -170)
list.ScrollBarThickness = 8
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = panel
round(list, 10)
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.Parent = list
local listPad = Instance.new("UIPadding")
listPad.PaddingLeft, listPad.PaddingRight, listPad.PaddingTop = UDim.new(0, 8), UDim.new(0, 8), UDim.new(0, 8)
listPad.Parent = list

local footer = text(panel, "", 40)
footer.AnchorPoint = Vector2.new(0, 1)
footer.Position = UDim2.new(0, 16, 1, -8)
footer.Size = UDim2.new(1, -32, 0, 44)

-- State -----------------------------------------------------------------------------------------------------------
type Item = { uid: number, id: string, tier: number, stats: { [string]: number } }
local inv: any = nil
local currentTab = "Build"
local picks: { [string]: number? } = {} -- socket -> uid chosen in the Build tab

local function pretty(id: string): string
	return (string.gsub(id, "_", " "))
end

local function statLine(s: { [string]: number }): string
	local out = {}
	for _, name in Parts.StatNames do
		local v = s[name] or 0
		if v > 0.004 then
			table.insert(out, string.format("%s +%.1f", name, v))
		end
	end
	return if #out > 0 then table.concat(out, "  ") else "no stats"
end

local function tierName(tier: number): string
	return inv.tiers[tier] and inv.tiers[tier].name or "?"
end

local function clear()
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function row(label: string, buttonText: string?, color: Color3?, onClick: (() -> ())?): TextButton?
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, 50)
	f.BackgroundColor3 = Color3.fromRGB(86, 60, 44)
	f.Parent = list
	round(f, 8)
	local t = text(f, label, 50)
	t.Size = UDim2.new(1, -150, 1, -8)
	t.Position = UDim2.fromOffset(10, 4)
	if buttonText then
		local b = button(f, buttonText, UDim2.fromOffset(130, 40), color or Color3.fromRGB(60, 150, 80))
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -6, 0.5, 0)
		if onClick then
			b.Activated:Connect(onClick)
		end
		return b
	end
	return nil
end

-- Tabs ------------------------------------------------------------------------------------------------------------
local render: () -> ()

local function partsFor(slotType: string): { Item }
	local out: { Item } = {}
	for _, it in inv.parts do
		local def = Parts.get(it.id)
		if def and def.slot == slotType then
			table.insert(out, it)
		end
	end
	table.sort(out, function(a: Item, b: Item)
		return a.id == b.id and a.uid < b.uid or a.id < b.id
	end)
	return out
end

local function renderBuild()
	-- Drop picks for parts that are gone (built, merged).
	local have: { [number]: Item } = {}
	for _, it in inv.parts do
		have[it.uid] = it
	end
	for socket, uid in picks do
		if uid and have[uid] == nil then
			picks[socket] = nil
		end
	end
	local total: { [string]: number } = {}
	local chosen = 0
	for _, socket in Parts.Sockets do
		local uid = picks[socket]
		local item = uid and have[uid]
		local label = socket .. ": " .. (if item then string.format("%s [%s]  %s", pretty(item.id), tierName(item.tier), statLine(item.stats)) else "(empty)")
		if item then
			chosen += 1
			for _, name in Parts.StatNames do
				total[name] = (total[name] or 0) + (item.stats[name] or 0)
			end
		end
		row(label, "CHANGE", Color3.fromRGB(70, 120, 200), function()
			-- Cycle through compatible parts not already used in another socket: empty -> first -> ... -> empty.
			local used: { [number]: boolean } = {}
			for s, u in picks do
				if s ~= socket and u then
					used[u] = true
				end
			end
			local options: { number } = {}
			for _, it in partsFor(Parts.SocketSlot[socket]) do
				if not used[it.uid] then
					table.insert(options, it.uid)
				end
			end
			-- empty -> first option -> ... -> last option -> empty
			local at = table.find(options, picks[socket] or -1) or 0
			picks[socket] = options[at + 1] -- nil past the end clears the socket
			render()
		end)
	end
	local build = row(string.format("Pet stats: %s", statLine(total)), "BUILD (" .. inv.buildFee .. "c)", Color3.fromRGB(230, 130, 40), function()
		if chosen > 0 then
			request:FireServer("Build", picks)
			picks = {}
		end
	end)
	if build then
		build.Active = chosen > 0
	end
end

local function renderMerge()
	local groups: { [string]: { id: string, tier: number, n: number } } = {}
	local order: { string } = {}
	for _, it in inv.parts do
		local key = it.id .. "#" .. it.tier
		if groups[key] == nil then
			groups[key] = { id = it.id, tier = it.tier, n = 0 }
			table.insert(order, key)
		end
		groups[key].n += 1
	end
	table.sort(order)
	if #order == 0 then
		row("No parts yet. Escape from an area with some!", nil)
	end
	for _, key in order do
		local g = groups[key]
		local canMerge = g.n >= inv.mergeCount and g.tier < #inv.tiers
		row(string.format("%s [%s]  x%d / %d", pretty(g.id), tierName(g.tier), g.n, inv.mergeCount), if g.tier < #inv.tiers then "MERGE" else "MAX", if canMerge then Color3.fromRGB(60, 150, 80) else Color3.fromRGB(90, 90, 90), function()
			if canMerge then
				request:FireServer("Merge", g.id, g.tier)
			end
		end)
	end
end

local function renderPets()
	if #inv.pets == 0 then
		row("No pets yet. Build one in the Build tab!", nil)
	end
	for _, pet in inv.pets do
		local equipped = table.find(inv.equipped, pet.uid) ~= nil
		local names = {}
		for _, socket in Parts.Sockets do
			local it = pet.slots[socket]
			if it then
				table.insert(names, (string.gsub(it.id, "_.*", "")))
			end
		end
		row(string.format("%s  (%s)", table.concat(names, "/"), statLine(pet.stats)), if equipped then "UNEQUIP" else "EQUIP", if equipped then Color3.fromRGB(190, 80, 60) else Color3.fromRGB(60, 150, 80), function()
			request:FireServer(if equipped then "Unequip" else "Equip", pet.uid)
		end)
	end
end

local function renderIndex()
	local species: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, def in Parts.all() do
		if not seen[def.species] then
			seen[def.species] = true
			table.insert(species, def.species)
		end
	end
	for _, sp in species do
		local bits = {}
		for _, slot in Parts.Slots do
			local best = inv.index[sp .. "_" .. slot]
			table.insert(bits, slot .. (if best then " " .. string.rep("*", best) else " ?"))
		end
		local complete = table.find(inv.species, sp) ~= nil
		row((if complete then "[DONE] " else "") .. sp .. ":  " .. table.concat(bits, "  "), nil)
	end
end

local tabs: { { name: string, draw: () -> () } } = {
	{ name = "Build", draw = renderBuild },
	{ name = "Merge", draw = renderMerge },
	{ name = "Pets", draw = renderPets },
	{ name = "Index", draw = renderIndex },
}
local tabButtons: { [string]: TextButton } = {}
for _, tab in tabs do
	local b = button(tabRow, string.upper(tab.name), UDim2.new(0.25, -6, 1, 0), Color3.fromRGB(110, 80, 60))
	tabButtons[tab.name] = b
	b.Activated:Connect(function()
		currentTab = tab.name
		render()
	end)
end

function render()
	if inv == nil then
		return
	end
	clear()
	for _, tab in tabs do
		tabButtons[tab.name].BackgroundColor3 = if tab.name == currentTab then Color3.fromRGB(230, 130, 40) else Color3.fromRGB(110, 80, 60)
		if tab.name == currentTab then
			tab.draw()
		end
	end
	footer.Text = string.format("Coins %d   Parts %d   Pets equipped %d/%d   Index %d/%d", inv.coins, #inv.parts, #inv.equipped, inv.petSlots, inv.indexFound, inv.indexTotal)
end

stateRemote.OnClientEvent:Connect(function(snapshot: any)
	inv = snapshot
	if panel.Visible then
		render()
	end
end)

openButton.Activated:Connect(function()
	panel.Visible = not panel.Visible
	if panel.Visible then
		request:FireServer("Sync")
		render()
	end
end)
close.Activated:Connect(function()
	panel.Visible = false
end)

-- The station is a lobby feature: hide it during a run.
local function refreshVisibility()
	local running = player:GetAttribute("RunState") == "running"
	openButton.Visible = not running
	if running then
		panel.Visible = false
	end
end
player:GetAttributeChangedSignal("RunState"):Connect(refreshVisibility)
refreshVisibility()
