--!strict
-- Minimal prototype HUD: bag slots, escape progress, chaser danger and short messages.
-- Everything shown comes from attributes the server sets on the player; nothing here affects the game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local function label(parent: Instance, name: string, size: UDim2, pos: UDim2, anchor: Vector2, textSize: number): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.Size = size
	t.Position = pos
	t.AnchorPoint = anchor
	t.BackgroundTransparency = 1
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0
	t.Font = Enum.Font.GothamBlack
	t.TextSize = textSize
	t.Parent = parent
	return t
end

-- Bag: one big box per slot (bottom centre).
local bagFrame = Instance.new("Frame")
bagFrame.Name = "Bag"
bagFrame.AnchorPoint = Vector2.new(0.5, 1)
bagFrame.Position = UDim2.fromScale(0.5, 0.97)
bagFrame.Size = UDim2.fromOffset(260, 90)
bagFrame.BackgroundTransparency = 1
bagFrame.Parent = gui
local bagTitle = label(bagFrame, "Title", UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, 0), Vector2.zero, 20)
-- Bag slots are drawn on demand: Robux bag slots have no upper limit, so there is no fixed maximum. Slots wrap into
-- rows of PER_ROW, and past MAX_DRAWN only the "BAG n/m" count is shown so a huge bag cannot flood the screen.
local slots: { Frame } = {}
local PER_ROW = 10
local MAX_DRAWN = 40
local function ensureSlot(i: number): Frame
	local f = slots[i]
	if f == nil then
		f = Instance.new("Frame")
		f.Name = "Slot" .. i
		f.Size = UDim2.fromOffset(60, 44)
		f.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
		f.BackgroundTransparency = 0.25
		f.BorderSizePixel = 0
		f.Parent = bagFrame
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 10)
		c.Parent = f
		slots[i] = f
	end
	return f
end

-- Escape progress bar (centre bottom, above the bag).
local escapeBack = Instance.new("Frame")
escapeBack.Name = "EscapeBar"
escapeBack.AnchorPoint = Vector2.new(0.5, 0.5)
escapeBack.Position = UDim2.fromScale(0.5, 0.72)
escapeBack.Size = UDim2.fromOffset(300, 26)
escapeBack.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
escapeBack.BackgroundTransparency = 0.2
escapeBack.Visible = false
escapeBack.Parent = gui
local escapeFill = Instance.new("Frame")
escapeFill.Name = "Fill"
escapeFill.Size = UDim2.fromScale(0, 1)
escapeFill.BackgroundColor3 = Color3.fromRGB(70, 255, 130)
escapeFill.BorderSizePixel = 0
escapeFill.Parent = escapeBack
local escapeText = label(escapeBack, "Text", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Vector2.zero, 16)
escapeText.Text = "ESCAPING..."

-- Danger: red edge glow and distance, top centre.
local danger = label(gui, "Danger", UDim2.fromOffset(300, 40), UDim2.fromScale(0.5, 0.06), Vector2.new(0.5, 0.5), 26)
local vignette = Instance.new("Frame")
vignette.Name = "Vignette"
vignette.Size = UDim2.fromScale(1, 1)
vignette.BackgroundColor3 = Color3.fromRGB(255, 0, 40)
vignette.BackgroundTransparency = 1
vignette.BorderSizePixel = 0
vignette.ZIndex = 0
vignette.Parent = gui

local banked = label(gui, "Banked", UDim2.fromOffset(240, 30), UDim2.fromScale(0.985, 0.03), Vector2.new(1, 0.5), 20)
banked.TextXAlignment = Enum.TextXAlignment.Right

local message = label(gui, "Message", UDim2.fromOffset(560, 60), UDim2.fromScale(0.5, 0.2), Vector2.new(0.5, 0.5), 28)
message.TextWrapped = true
message.TextTransparency = 1
message.TextStrokeTransparency = 1

local function refresh()
	local state = player:GetAttribute("RunState")
	local running = state == "running"
	local count = (player:GetAttribute("BagCount") :: number?) or 0
	local capacity = (player:GetAttribute("BagCapacity") :: number?) or 3

	bagFrame.Visible = running
	bagTitle.Text = string.format("BAG %d/%d", count, capacity)
	local drawn = math.min(capacity, MAX_DRAWN)
	local columns = math.min(drawn, PER_ROW)
	local rows = math.ceil(drawn / PER_ROW)
	bagFrame.Size = UDim2.fromOffset(math.max(columns, 1) * 66, 30 + rows * 50)
	for i = 1, drawn do
		local f = ensureSlot(i)
		f.Visible = true
		f.Position = UDim2.fromOffset(((i - 1) % PER_ROW) * 66, 30 + math.floor((i - 1) / PER_ROW) * 50)
		f.BackgroundColor3 = if i <= count then Color3.fromRGB(255, 200, 70) else Color3.fromRGB(30, 30, 40)
	end
	for i = drawn + 1, #slots do
		slots[i].Visible = false
	end

	local progress = ((player:GetAttribute("EscapeProgress") :: number?) or 0) / 100
	escapeBack.Visible = running and progress > 0
	escapeFill.Size = UDim2.fromScale(progress, 1)

	local distance = (player:GetAttribute("ChaserDistance") :: number?) or 999
	local protected = player:GetAttribute("Protected") == true
	danger.Visible = running
	if protected then
		danger.Text = "PROTECTED"
		danger.TextColor3 = Color3.fromRGB(120, 200, 255)
		vignette.BackgroundTransparency = 1
	else
		danger.Text = string.format("CHASER %d studs", distance)
		danger.TextColor3 = if distance < 40 then Color3.fromRGB(255, 80, 80) else Color3.new(1, 1, 1)
		vignette.BackgroundTransparency = if running then math.clamp(distance / 60, 0.55, 1) else 1
	end

	banked.Text = string.format("BANKED PARTS: %d", ((player:GetAttribute("Banked") :: number?) or 0))
end

for _, name in { "RunState", "BagCount", "BagCapacity", "EscapeProgress", "ChaserDistance", "Protected", "Banked" } do
	player:GetAttributeChangedSignal(name):Connect(refresh)
end
refresh()

local notify = ReplicatedStorage:WaitForChild("Notify") :: RemoteEvent
local shown = 0
notify.OnClientEvent:Connect(function(text: string)
	shown += 1
	local mine = shown
	message.Text = text
	message.TextTransparency = 0
	message.TextStrokeTransparency = 0
	task.delay(3, function()
		if shown == mine then
			TweenService:Create(message, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end)
