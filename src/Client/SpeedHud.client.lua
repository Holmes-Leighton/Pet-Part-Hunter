--!strict
-- Speed HUD (spec section 3, "Look and feel"): big outlined Speed total, level bar, multiplier line, a Rebirth button
-- on the left and a pad-purchase button on the right. Mobile-first: two large buttons, nothing else on screen.
-- It only reads attributes the server publishes and sends requests; the server decides everything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local request = ReplicatedStorage:WaitForChild("ProgressRequest") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterSpeedHud"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local function outlined(parent: Instance, name: string, size: UDim2, pos: UDim2, anchor: Vector2, textSize: number, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.Size = size
	t.Position = pos
	t.AnchorPoint = anchor
	t.BackgroundTransparency = 1
	t.TextColor3 = color or Color3.new(1, 1, 1)
	t.TextStrokeColor3 = Color3.fromRGB(20, 14, 10)
	t.TextStrokeTransparency = 0
	t.Font = Enum.Font.GothamBlack
	t.TextSize = textSize
	t.Parent = parent
	return t
end

local function chunkyButton(name: string, size: UDim2, pos: UDim2, anchor: Vector2, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = pos
	b.AnchorPoint = anchor
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextStrokeTransparency = 0
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(20, 14, 10)
	stroke.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.Parent = b
	return b
end

-- Lobby panel: multiplier line, Speed total, level bar.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.fromScale(0.5, 0.97)
panel.Size = UDim2.fromOffset(440, 130)
panel.BackgroundTransparency = 1
panel.Parent = gui
local multLabel = outlined(panel, "Multipliers", UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), Vector2.zero, 16, Color3.fromRGB(255, 200, 90))
local speedLabel = outlined(panel, "Speed", UDim2.new(1, 0, 0, 52), UDim2.fromOffset(0, 24), Vector2.zero, 46)
local barBack = Instance.new("Frame")
barBack.Name = "LevelBar"
barBack.Position = UDim2.fromOffset(0, 82)
barBack.Size = UDim2.new(1, 0, 0, 38)
barBack.BackgroundColor3 = Color3.fromRGB(40, 30, 24)
barBack.BorderSizePixel = 0
barBack.Parent = panel
local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 10)
barCorner.Parent = barBack
local barStroke = Instance.new("UIStroke")
barStroke.Thickness = 3
barStroke.Color = Color3.fromRGB(20, 14, 10)
barStroke.Parent = barBack
local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.fromRGB(226, 178, 120)
barFill.BorderSizePixel = 0
barFill.Parent = barBack
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 10)
fillCorner.Parent = barFill
local levelLabel = outlined(barBack, "Level", UDim2.new(0.5, -10, 1, 0), UDim2.fromOffset(10, 0), Vector2.zero, 24)
levelLabel.TextXAlignment = Enum.TextXAlignment.Left
local progressLabel = outlined(barBack, "Progress", UDim2.new(0.5, -10, 1, 0), UDim2.new(0.5, 0, 0, 0), Vector2.zero, 24)
progressLabel.TextXAlignment = Enum.TextXAlignment.Right

-- Rebirth (left) and Buy Pad (right).
local rebirthButton = chunkyButton("Rebirth", UDim2.fromOffset(110, 96), UDim2.fromScale(0.03, 0.5), Vector2.new(0, 0.5), Color3.fromRGB(150, 60, 200))
local padButton = chunkyButton("BuyPad", UDim2.fromOffset(130, 90), UDim2.fromScale(0.97, 0.5), Vector2.new(1, 0.5), Color3.fromRGB(60, 150, 80))
rebirthButton.Activated:Connect(function()
	request:FireServer("Rebirth")
end)
padButton.Activated:Connect(function()
	local owned = (player:GetAttribute("PadTier") :: number?) or 1
	request:FireServer("BuyPad", owned + 1)
end)

-- In a run only a small walk-speed readout shows (the bag HUD owns the bottom of the screen).
local runSpeed = outlined(gui, "RunSpeed", UDim2.fromOffset(220, 28), UDim2.fromScale(0.015, 0.03), Vector2.zero, 20)
runSpeed.TextXAlignment = Enum.TextXAlignment.Left

local function compact(n: number): string
	if n >= 1e9 then
		return string.format("%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.1fK", n / 1e3)
	end
	return string.format("%d", n)
end

local function num(name: string, default: number): number
	return (player:GetAttribute(name) :: number?) or default
end

local pulse: Tween? = nil

local function refresh()
	local running = player:GetAttribute("RunState") == "running"
	panel.Visible = not running
	rebirthButton.Visible = not running
	runSpeed.Visible = running

	local level, cap = num("Level", 1), num("LevelCap", Config.Speed.LevelsPerRebirth)
	local atCap = player:GetAttribute("AtLevelCap") == true
	local canRebirth = player:GetAttribute("CanRebirth") == true
	local rebirths = num("Rebirths", 0)
	local maxed = rebirths >= Config.Speed.MaxRebirths

	runSpeed.Text = string.format("SPEED %d", num("WalkSpeedStat", Config.Player.WalkSpeed))

	speedLabel.Text = compact(num("Speed", 0)) .. " Speed"
	local mult = num("GainMult", 1)
	multLabel.Text = string.format("Speed gain x%s  |  Rebirths %d", if mult % 1 == 0 then tostring(mult) else string.format("%.2f", mult), rebirths)
	levelLabel.Text = "Level " .. level
	if atCap then
		progressLabel.Text = if maxed then "MAX" else "REBIRTH!"
		barFill.Size = UDim2.fromScale(1, 1)
	else
		local into, cost = num("LevelInto", 0), math.max(1, num("LevelCost", 100))
		progressLabel.Text = string.format("%s / %s", compact(into), compact(cost))
		barFill.Size = UDim2.fromScale(math.clamp(into / cost, 0, 1), 1)
	end

	rebirthButton.Text = if maxed then "MAX\nREBIRTH" else string.format("REBIRTH\nLv %d  x%.2f", cap, num("NextRebirthMult", 1))
	rebirthButton.BackgroundColor3 = if canRebirth then Color3.fromRGB(190, 70, 240) else Color3.fromRGB(90, 70, 110)
	if canRebirth and pulse == nil then
		pulse = TweenService:Create(rebirthButton, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Size = UDim2.fromOffset(122, 106) })
		pulse:Play()
	elseif not canRebirth and pulse then
		pulse:Cancel()
		pulse = nil
		rebirthButton.Size = UDim2.fromOffset(110, 96)
	end

	local owned = num("PadTier", 1)
	local nextPad = Config.Pads[owned + 1]
	padButton.Visible = not running and nextPad ~= nil
	if nextPad then
		local needsRebirth = nextPad.rebirths > rebirths
		padButton.Text = string.format("PAD %d\n+%d/s\n%s", nextPad.tier, nextPad.rate, if needsRebirth then "Rebirth " .. nextPad.rebirths else compact(nextPad.coins) .. " coins")
		padButton.BackgroundColor3 = if not needsRebirth and num("Coins", 0) >= nextPad.coins then Color3.fromRGB(60, 170, 90) else Color3.fromRGB(80, 90, 85)
	end
end

for _, name in { "RunState", "Speed", "Level", "LevelCap", "AtLevelCap", "LevelInto", "LevelCost", "CanRebirth", "Rebirths", "GainMult", "PadTier", "Coins", "WalkSpeedStat", "NextRebirthMult" } do
	player:GetAttributeChangedSignal(name):Connect(refresh)
end
refresh()
