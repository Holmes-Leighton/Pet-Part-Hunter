--!strict
-- Trading UI (spec section 5): pick a player, answer requests, and the trade window itself. Both sides add parts and
-- pets, each LOCKS in, a short countdown runs, then each CONFIRMS and the server swaps everything. Changing your offer
-- at any time resets every lock, and a lopsided trade shows a warning that the generous side must acknowledge.
-- The client only asks; the server validates, logs and performs the swap.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local Parts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Parts"))
local request = ReplicatedStorage:WaitForChild("TradeRequest") :: RemoteEvent
local stateRemote = ReplicatedStorage:WaitForChild("TradeState") :: RemoteEvent
local inventoryRemote = ReplicatedStorage:WaitForChild("InventoryState") :: RemoteEvent
local craftRequest = ReplicatedStorage:WaitForChild("CraftRequest") :: RemoteEvent

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterTradeHud"
gui.ResetOnSpawn = false
gui.DisplayOrder = 10
gui.Parent = player:WaitForChild("PlayerGui")

local GREEN, RED, GREY = Color3.fromRGB(60, 150, 80), Color3.fromRGB(200, 60, 60), Color3.fromRGB(90, 90, 90)

local inv: any = nil -- latest InventoryState (own parts and pets)
local trade: any = nil -- latest trade snapshot, nil when not trading
local adding = false -- left list shows the inventory picker instead of the current offer

local function pretty(id: string): string
	return (string.gsub(id, "_", " "))
end

local function statLine(s: { [string]: number }?): string
	if s == nil then
		return ""
	end
	local out = {}
	for _, name in Parts.StatNames do
		local v = s[name] or 0
		if v > 0.004 then
			table.insert(out, string.format("%s +%.1f", name, v))
		end
	end
	return table.concat(out, " ")
end

local function tierMark(tier: number): string
	return string.rep("*", tier)
end

-- Opening button and player list -----------------------------------------------------------------------------------
local openButton = UiKit.button(gui, "TRADE", UDim2.fromOffset(110, 64), Color3.fromRGB(70, 160, 160))
openButton.AnchorPoint = Vector2.new(0, 0.5)
openButton.Position = UDim2.new(0.03, 0, 0.5, 334)

local picker = Instance.new("Frame")
picker.AnchorPoint = Vector2.new(0.5, 0.5)
picker.Position = UDim2.fromScale(0.5, 0.5)
picker.Size = UDim2.fromScale(0.5, 0.6)
picker.BackgroundColor3 = Color3.fromRGB(70, 48, 34)
picker.Visible = false
picker.Parent = gui
UiKit.round(picker, 16)
UiKit.outline(picker, 4)
local pickerTitle = UiKit.label(picker, "TRADE WITH...", UDim2.new(1, -80, 0, 34))
pickerTitle.Position = UDim2.fromOffset(16, 8)
local pickerClose = UiKit.button(picker, "X", UDim2.fromOffset(44, 40), RED)
pickerClose.AnchorPoint = Vector2.new(1, 0)
pickerClose.Position = UDim2.new(1, -10, 0, 8)
local playerList = UiKit.list(picker, UDim2.fromOffset(12, 54), UDim2.new(1, -24, 1, -66))

local function renderPlayers()
	for _, c in playerList:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local any = false
	for _, other in Players:GetPlayers() do
		if other ~= player then
			any = true
			UiKit.row(playerList, other.DisplayName, "TRADE", GREEN, function()
				request:FireServer("Invite", other.UserId)
				picker.Visible = false
			end)
		end
	end
	if not any then
		UiKit.row(playerList, "No other players in this server.", nil)
	end
end

openButton.Activated:Connect(function()
	picker.Visible = not picker.Visible
	if picker.Visible then
		renderPlayers()
	end
end)
pickerClose.Activated:Connect(function()
	picker.Visible = false
end)

-- Invite banner ---------------------------------------------------------------------------------------------------------
local banner = Instance.new("Frame")
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.new(0.5, 0, 0, 130)
banner.Size = UDim2.fromOffset(380, 70)
banner.BackgroundColor3 = Color3.fromRGB(60, 42, 30)
banner.Visible = false
banner.Parent = gui
UiKit.round(banner, 12)
UiKit.outline(banner, 3)
local bannerText = UiKit.label(banner, "", UDim2.new(1, -20, 0, 28))
bannerText.Position = UDim2.fromOffset(10, 6)
local acceptBtn = UiKit.button(banner, "ACCEPT", UDim2.fromOffset(170, 30), GREEN)
acceptBtn.Position = UDim2.fromOffset(10, 34)
local declineBtn = UiKit.button(banner, "DECLINE", UDim2.fromOffset(170, 30), RED)
declineBtn.Position = UDim2.fromOffset(200, 34)
acceptBtn.Activated:Connect(function()
	request:FireServer("Respond", true)
	banner.Visible = false
end)
declineBtn.Activated:Connect(function()
	request:FireServer("Respond", false)
	banner.Visible = false
end)

-- Trade window ---------------------------------------------------------------------------------------------------------
local window = Instance.new("Frame")
window.AnchorPoint = Vector2.new(0.5, 0.5)
window.Position = UDim2.fromScale(0.5, 0.5)
window.Size = UDim2.fromScale(0.86, 0.86)
window.BackgroundColor3 = Color3.fromRGB(70, 48, 34)
window.Visible = false
window.Parent = gui
UiKit.round(window, 16)
UiKit.outline(window, 4)

local title = UiKit.label(window, "", UDim2.new(1, -24, 0, 30))
title.Position = UDim2.fromOffset(14, 6)
local valueLine = UiKit.label(window, "", UDim2.new(1, -24, 0, 24))
valueLine.Position = UDim2.fromOffset(14, 36)
valueLine.TextColor3 = Color3.fromRGB(255, 220, 90)
local warning = UiKit.label(window, "", UDim2.new(1, -24, 0, 26))
warning.Position = UDim2.fromOffset(14, 62)
warning.TextColor3 = Color3.fromRGB(255, 110, 110)

local leftHeader = UiKit.label(window, "YOU OFFER", UDim2.new(0.5, -20, 0, 22))
leftHeader.Position = UDim2.fromOffset(14, 92)
local rightHeader = UiKit.label(window, "THEY OFFER", UDim2.new(0.5, -20, 0, 22))
rightHeader.Position = UDim2.new(0.5, 8, 0, 92)
local leftList = UiKit.list(window, UDim2.fromOffset(14, 116), UDim2.new(0.5, -22, 1, -190))
local rightList = UiKit.list(window, UDim2.new(0.5, 8, 0, 116), UDim2.new(0.5, -22, 1, -190))

local buttons = Instance.new("Frame")
buttons.BackgroundTransparency = 1
buttons.AnchorPoint = Vector2.new(0, 1)
buttons.Position = UDim2.new(0, 14, 1, -10)
buttons.Size = UDim2.new(1, -28, 0, 52)
buttons.Parent = window
local btnLayout = Instance.new("UIListLayout")
btnLayout.FillDirection = Enum.FillDirection.Horizontal
btnLayout.Padding = UDim.new(0, 8)
btnLayout.Parent = buttons
local addBtn = UiKit.button(buttons, "ADD ITEMS", UDim2.new(0.25, -6, 1, 0), Color3.fromRGB(70, 130, 210))
local lockBtn = UiKit.button(buttons, "LOCK IN", UDim2.new(0.25, -6, 1, 0), Color3.fromRGB(230, 130, 40))
local confirmBtn = UiKit.button(buttons, "CONFIRM", UDim2.new(0.25, -6, 1, 0), GREEN)
local cancelBtn = UiKit.button(buttons, "CANCEL", UDim2.new(0.25, -6, 1, 0), RED)

local function clearList(list: ScrollingFrame)
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function partLabel(it: any): string
	return string.format("%s %s  %s", pretty(it.id), tierMark(it.tier), statLine(it.stats))
end

local function petLabel(pet: any): string
	local names = {}
	for _, socket in Parts.Sockets do
		local it = pet.slots[socket]
		if it then
			table.insert(names, (string.gsub(it.id, "_.*", "")))
		end
	end
	return "PET: " .. table.concat(names, "/") .. "  " .. statLine(pet.stats)
end

-- The current offer as a flat list of uids, for sending changes.
local function offerUids(): ({ number }, { number })
	local ps, pets = {}, {}
	for _, it in trade.mine.parts do
		table.insert(ps, it.uid)
	end
	for _, pet in trade.mine.pets do
		table.insert(pets, pet.uid)
	end
	return ps, pets
end

local function sendOffer(ps: { number }, pets: { number })
	request:FireServer("SetOffer", ps, pets)
end

local function renderWindow()
	if trade == nil then
		window.Visible = false
		return
	end
	local open = trade.status == "open"
	window.Visible = true
	title.Text = string.format("TRADING WITH %s", string.upper(trade.other.name))
	valueLine.Text = string.format("Value  you give %d   they give %d", trade.value.mine, trade.value.theirs)
	if not open then
		warning.Text = "Trade " .. trade.status .. (if trade.reason then ": " .. trade.reason else "")
		warning.TextColor3 = if trade.status == "completed" then Color3.fromRGB(120, 255, 140) else Color3.fromRGB(255, 190, 110)
	elseif trade.lopsided then
		warning.Text = if trade.iAmGiver then "WARNING: you are giving much more than you get!" else "This trade looks lopsided in your favour."
		warning.TextColor3 = Color3.fromRGB(255, 110, 110)
	else
		warning.Text = ""
	end

	-- Right: what they offer (read-only). Left: your offer, or the picker.
	clearList(rightList)
	for _, it in trade.theirs.parts do
		UiKit.row(rightList, partLabel(it), nil)
	end
	for _, pet in trade.theirs.pets do
		UiKit.row(rightList, petLabel(pet), nil)
	end
	if #trade.theirs.parts + #trade.theirs.pets == 0 then
		UiKit.row(rightList, "Nothing yet", nil)
	end

	clearList(leftList)
	if adding and open and inv then
		leftHeader.Text = "TAP TO ADD"
		local ps, pets = offerUids()
		local offeredPart: { [number]: boolean } = {}
		for _, u in ps do
			offeredPart[u] = true
		end
		local offeredPet: { [number]: boolean } = {}
		for _, u in pets do
			offeredPet[u] = true
		end
		for _, it in inv.parts do
			if not offeredPart[it.uid] then
				UiKit.row(leftList, partLabel(it), "ADD", GREEN, function()
					local p2 = table.clone(ps)
					table.insert(p2, it.uid)
					sendOffer(p2, pets)
				end)
			end
		end
		for _, pet in inv.pets do
			if not offeredPet[pet.uid] and not table.find(inv.equipped, pet.uid) then
				UiKit.row(leftList, petLabel(pet), "ADD", GREEN, function()
					local pt2 = table.clone(pets)
					table.insert(pt2, pet.uid)
					sendOffer(ps, pt2)
				end)
			end
		end
	else
		leftHeader.Text = "YOU OFFER"
		for _, it in trade.mine.parts do
			UiKit.row(leftList, partLabel(it), if open then "REMOVE" else nil, RED, function()
				local ps, pets = offerUids()
				table.remove(ps, table.find(ps, it.uid) :: number)
				sendOffer(ps, pets)
			end)
		end
		for _, pet in trade.mine.pets do
			UiKit.row(leftList, petLabel(pet), if open then "REMOVE" else nil, RED, function()
				local ps, pets = offerUids()
				table.remove(pets, table.find(pets, pet.uid) :: number)
				sendOffer(ps, pets)
			end)
		end
		if #trade.mine.parts + #trade.mine.pets == 0 then
			UiKit.row(leftList, "Tap ADD ITEMS to offer parts or pets", nil)
		end
	end

	-- Buttons.
	addBtn.Text = if adding then "DONE" else "ADD ITEMS"
	addBtn.Visible = open
	lockBtn.Visible = open
	lockBtn.Text = if trade.lockedMine then "UNLOCK" else "LOCK IN"
	lockBtn.BackgroundColor3 = if trade.lockedMine then Color3.fromRGB(190, 90, 60) else Color3.fromRGB(230, 130, 40)
	local bothLocked = trade.lockedMine and trade.lockedTheirs
	confirmBtn.Visible = open
	if trade.confirmedMine then
		confirmBtn.Text = "WAITING..."
		confirmBtn.BackgroundColor3 = GREY
	elseif not bothLocked then
		confirmBtn.Text = if trade.lockedTheirs then "THEY LOCKED" else "CONFIRM"
		confirmBtn.BackgroundColor3 = GREY
	elseif trade.wait > 0 then
		confirmBtn.Text = string.format("CONFIRM (%d)", math.ceil(trade.wait))
		confirmBtn.BackgroundColor3 = GREY
	else
		confirmBtn.Text = if trade.iAmGiver then "I UNDERSTAND - CONFIRM" else "CONFIRM"
		confirmBtn.BackgroundColor3 = GREEN
	end
	cancelBtn.Text = if open then "CANCEL" else "CLOSE"
	if trade.lockedTheirs and open then
		rightHeader.Text = "THEY OFFER (locked)"
	else
		rightHeader.Text = "THEY OFFER"
	end
	if trade.confirmedTheirs and open then
		rightHeader.Text = "THEY OFFER (confirmed)"
	end
end

addBtn.Activated:Connect(function()
	adding = not adding
	renderWindow()
end)
lockBtn.Activated:Connect(function()
	adding = false
	request:FireServer(if trade and trade.lockedMine then "Unlock" else "Lock")
end)
confirmBtn.Activated:Connect(function()
	if trade and trade.lockedMine and trade.lockedTheirs and trade.wait <= 0 and not trade.confirmedMine then
		request:FireServer("Confirm", trade.iAmGiver == true)
	end
end)
cancelBtn.Activated:Connect(function()
	if trade and trade.status == "open" then
		request:FireServer("Cancel")
	else
		trade = nil
		renderWindow()
	end
end)

stateRemote.OnClientEvent:Connect(function(msg: any)
	if type(msg) ~= "table" then
		return
	end
	if msg.kind == "invite" then
		bannerText.Text = string.format("%s wants to trade", tostring(msg.fromName))
		banner.Visible = true
		task.delay((msg.seconds :: number?) or 30, function()
			banner.Visible = false
		end)
	elseif msg.kind == "invite_gone" then
		banner.Visible = false
	elseif msg.kind == "state" then
		trade = msg
		if trade.status == "open" then
			picker.Visible = false
		else
			adding = false
			-- A finished window stays up briefly so the result can be read, then closes itself.
			local id = trade.id
			task.delay(4, function()
				if trade and trade.id == id and trade.status ~= "open" then
					trade = nil
					renderWindow()
				end
			end)
		end
		renderWindow()
	end
end)

inventoryRemote.OnClientEvent:Connect(function(snapshot: any)
	inv = snapshot
	if trade and adding then
		renderWindow()
	end
end)

local function refreshVisibility()
	local running = player:GetAttribute("RunState") == "running"
	openButton.Visible = not running
	if running then
		picker.Visible = false
	end
end
player:GetAttributeChangedSignal("RunState"):Connect(refreshVisibility)
Players.PlayerAdded:Connect(function()
	if picker.Visible then
		renderPlayers()
	end
end)
Players.PlayerRemoving:Connect(function()
	task.defer(function()
		if picker.Visible then
			renderPlayers()
		end
	end)
end)
refreshVisibility()
craftRequest:FireServer("Sync") -- ask for the inventory so the picker has something to show
