--!strict
-- Events on the client (spec section 8). Does two things:
--   * registers every event's exclusive parts in the part table, so pets, the Part Index and the crafting screens can
--     name and colour them (the server publishes them as the ReplicatedStorage attribute "EventParts"),
--   * shows a banner for each running event: its name, what it does, how long is left, and the community goal.
-- Everything shown is read from attributes the server sets; the client changes nothing.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Parts = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Parts"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local player = Players.LocalPlayer

local function decode(name: string): any
	local json = ReplicatedStorage:GetAttribute(name)
	if type(json) ~= "string" then
		return nil
	end
	local ok, value = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	return if ok then value else nil
end

-- Event parts ----------------------------------------------------------------------------------------------------------
local function registerParts()
	local all = decode("EventParts")
	if type(all) ~= "table" then
		return
	end
	for eventId, info in all do
		if type(eventId) == "string" and type(info) == "table" and type(info.parts) == "table" then
			Parts.registerEvent(eventId, info.parts, info.tradable == true)
		end
	end
end
ReplicatedStorage:GetAttributeChangedSignal("EventParts"):Connect(registerParts)
registerParts()

-- Banner ---------------------------------------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterEvents"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local stack = Instance.new("Frame")
stack.BackgroundTransparency = 1
stack.Position = UDim2.fromScale(0.015, 0.1)
stack.Size = UDim2.fromOffset(330, 200)
stack.Parent = gui
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = stack

local active: { any } = {}
local labels: { [string]: TextLabel } = {}

local function countdown(seconds: number): string
	if seconds <= 0 then
		return "ending"
	end
	local d = math.floor(seconds / 86400)
	local h = math.floor(seconds % 86400 / 3600)
	local m = math.floor(seconds % 3600 / 60)
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm %ds", m, math.floor(seconds % 60))
end

local function render()
	local seen: { [string]: boolean } = {}
	for _, ev in active do
		seen[ev.id] = true
		local box = labels[ev.id]
		if box == nil then
			local f = Instance.new("Frame")
			f.Size = UDim2.fromOffset(320, 58)
			f.BackgroundColor3 = Color3.fromRGB(110, 50, 150)
			f.BackgroundTransparency = 0.15
			f.Parent = stack
			UiKit.round(f, 10)
			UiKit.outline(f, 2)
			local t = UiKit.label(f, "", UDim2.new(1, -16, 1, -8))
			t.Position = UDim2.fromOffset(8, 4)
			t.TextWrapped = true
			t.TextScaled = false
			t.TextSize = 15
			t.TextYAlignment = Enum.TextYAlignment.Center
			labels[ev.id] = t
			box = t
		end
		local left = ev.endsAt - workspace:GetServerTimeNow()
		local line = string.upper(ev.name) .. "  -  " .. countdown(left)
		if ev.text and ev.text ~= "" then
			line ..= "\n" .. ev.text
		end
		if ev.goal then
			line ..= string.format("\nCommunity goal: %d / %d parts", ev.goal.progress, ev.goal.target)
		end
		box.Text = line
	end
	for id, box in labels do
		if not seen[id] then
			box.Parent:Destroy()
			labels[id] = nil
		end
	end
end

local function reload()
	local list = decode("ActiveEvents")
	active = if type(list) == "table" then list else {}
	render()
end
ReplicatedStorage:GetAttributeChangedSignal("ActiveEvents"):Connect(reload)
reload()

local elapsed = 0.0
RunService.Heartbeat:Connect(function(dt)
	elapsed += dt
	if elapsed >= 1 then
		elapsed = 0
		render() -- keeps the countdown moving
	end
end)

-- Banners get out of the way during a run so they never cover the chase.
local function refreshVisibility()
	stack.Visible = player:GetAttribute("RunState") ~= "running"
end
player:GetAttributeChangedSignal("RunState"):Connect(refreshVisibility)
refreshVisibility()
