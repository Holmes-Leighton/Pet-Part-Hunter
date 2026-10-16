--!strict
-- The in-game admin panel (spec section 8: quick actions in the game, deeper review on the external dashboard). It only
-- appears for players the server has given a role (the AdminRole attribute), but that is just a convenience: every command
-- goes to the server, which checks the real role, validates the arguments, logs the action and refuses anything not allowed.
-- Nothing in this script can give anyone admin powers.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local request = ReplicatedStorage:WaitForChild("AdminRequest") :: RemoteEvent
local resultRemote = ReplicatedStorage:WaitForChild("AdminResult") :: RemoteEvent

local player = Players.LocalPlayer
local GREEN, RED, BLUE, ORANGE, GREY = Color3.fromRGB(60, 150, 80), Color3.fromRGB(200, 60, 60), Color3.fromRGB(70, 130, 210), Color3.fromRGB(230, 130, 40), Color3.fromRGB(90, 90, 90)

local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterAdmin"
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

-- Calls -------------------------------------------------------------------------------------------------------------------
local nextId = 0
local callbacks: { [number]: (boolean, string, any) -> () } = {}
local status: TextLabel

local function call(action: string, args: { [string]: any }, cb: ((boolean, string, any) -> ())?)
	nextId += 1
	if cb then
		callbacks[nextId] = cb
	end
	request:FireServer(nextId, action, args)
end

resultRemote.OnClientEvent:Connect(function(msg: any)
	if type(msg) ~= "table" then
		return
	end
	if status then
		status.Text = (if msg.ok then "OK: " else "NO: ") .. tostring(msg.message)
		status.TextColor3 = if msg.ok then Color3.fromRGB(140, 255, 150) else Color3.fromRGB(255, 130, 130)
	end
	local cb = callbacks[msg.rid]
	if cb then
		callbacks[msg.rid] = nil
		cb(msg.ok == true, tostring(msg.message), msg.data)
	end
end)

-- Layout ------------------------------------------------------------------------------------------------------------------
local openButton = UiKit.button(gui, "ADMIN", UDim2.fromOffset(80, 32), Color3.fromRGB(120, 60, 160))
openButton.Position = UDim2.fromOffset(10, 8)
openButton.Parent = gui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.9, 0.9)
panel.BackgroundColor3 = Color3.fromRGB(40, 32, 52)
panel.Visible = false
panel.Parent = gui
UiKit.round(panel, 14)
UiKit.outline(panel, 4)

local title = UiKit.label(panel, "ADMIN", UDim2.new(1, -90, 0, 30))
title.Position = UDim2.fromOffset(14, 6)
local close = UiKit.button(panel, "X", UDim2.fromOffset(44, 36), RED)
close.AnchorPoint = Vector2.new(1, 0)
close.Position = UDim2.new(1, -10, 0, 6)

local tabRow = Instance.new("Frame")
tabRow.BackgroundTransparency = 1
tabRow.Position = UDim2.fromOffset(10, 46)
tabRow.Size = UDim2.new(1, -20, 0, 36)
tabRow.Parent = panel
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabRow

local list = UiKit.list(panel, UDim2.fromOffset(10, 88), UDim2.new(1, -20, 1, -170))
status = UiKit.label(panel, "", UDim2.new(1, -20, 0, 26))
status.AnchorPoint = Vector2.new(0, 1)
status.Position = UDim2.new(0, 10, 1, -6)
status.TextScaled = false
status.TextSize = 16

-- A text box row: a label and an input, returned so its text can be read.
local function inputRow(labelText: string, placeholder: string, default: string?): TextBox
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, 40)
	f.BackgroundColor3 = Color3.fromRGB(70, 56, 90)
	f.Parent = list
	UiKit.round(f, 8)
	local l = UiKit.label(f, labelText, UDim2.new(0.3, 0, 1, -8))
	l.Position = UDim2.fromOffset(8, 4)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.68, -10, 1, -8)
	box.Position = UDim2.new(0.3, 4, 0, 4)
	box.BackgroundColor3 = Color3.fromRGB(30, 24, 40)
	box.TextColor3 = Color3.new(1, 1, 1)
	box.PlaceholderText = placeholder
	box.Text = default or ""
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Gotham
	box.TextSize = 16
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = f
	UiKit.round(box, 6)
	return box
end

local function clear()
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function line(text: string)
	UiKit.row(list, text, nil)
end

local function timeText(t: number): string
	return os.date("%d %b %H:%M", t)
end

-- Tabs ----------------------------------------------------------------------------------------------------------------------
local show: (string) -> ()
local selected: { userId: number, name: string }? = nil

local function showPlayers()
	clear()
	if selected then
		local sel = selected
		UiKit.row(list, "Selected: " .. sel.name .. " (" .. sel.userId .. ")", "BACK", GREY, function()
			selected = nil
			show("Players")
		end)
		local reason = inputRow("Reason", "required for most actions")
		local amount = inputRow("Amount", "coins", "1000")
		local partId = inputRow("Part id", "e.g. Kraken_Head", "")
		local function args(extra: { [string]: any }): { [string]: any }
			local a: { [string]: any } = { userId = sel.userId, reason = reason.Text }
			for k, v in extra do
				a[k] = v
			end
			return a
		end
		UiKit.row(list, "Look at their inventory", "INSPECT", BLUE, function()
			call("inspect", { userId = sel.userId }, function(ok, _, data)
				if ok then
					status.Text = HttpService:JSONEncode(data.summary)
				end
			end)
		end)
		UiKit.row(list, "Give coins", "GIVE", GREEN, function()
			call("grant_coins", args({ amount = tonumber(amount.Text) }))
		end)
		UiKit.row(list, "Take coins", "TAKE", ORANGE, function()
			call("remove_coins", args({ amount = tonumber(amount.Text) }))
		end)
		UiKit.row(list, "Give a part (tier 1)", "GIVE", GREEN, function()
			call("grant_part", args({ partId = partId.Text, tier = 1, count = 1 }))
		end)
		UiKit.row(list, "Remove from the game for now", "KICK", ORANGE, function()
			call("kick", args({}))
		end)
		UiKit.row(list, "Ban for 24 hours", "BAN 1D", RED, function()
			call("ban", args({ seconds = 86400 }))
		end)
		UiKit.row(list, "Ban permanently", "BAN", RED, function()
			call("ban", args({ seconds = 0 }))
		end)
		UiKit.row(list, "Lift their ban", "UNBAN", GREEN, function()
			call("unban", { userId = sel.userId })
		end)
		UiKit.row(list, "Recent trades", "TRADES", BLUE, function()
			call("trades", { userId = sel.userId }, function(ok, _, data)
				if ok and type(data) == "table" then
					status.Text = string.format("%d trade(s); newest: %s", #data, if #data > 0 then data[#data].s .. " with " .. data[#data].w else "none")
				end
			end)
		end)
		UiKit.row(list, "Restore an earlier copy of their data", "SNAPSHOTS", BLUE, function()
			call("snapshots", { userId = sel.userId }, function(ok, _, data)
				if not ok or type(data) ~= "table" then
					return
				end
				clear()
				UiKit.row(list, "Snapshots (oldest first). Needs a reason above.", "BACK", GREY, function()
					show("Players")
				end)
				for i, snap in data do
					UiKit.row(list, string.format("#%d  %s  coins %s  parts %s", i, timeText(snap.t), tostring(snap.summary.coins), tostring(snap.summary.parts)), "ROLLBACK", RED, function()
						call("rollback", args({ index = i }))
					end)
				end
			end)
		end)
		return
	end
	UiKit.row(list, "Players on this server", "REFRESH", BLUE, function()
		show("Players")
	end)
	call("players", {}, function(ok, _, data)
		if not ok or type(data) ~= "table" then
			return
		end
		for _, p in data do
			UiKit.row(list, string.format("%s  Lv%d  %d coins  %s%s", p.name, p.level, p.coins, p.area, if p.role ~= "none" then "  [" .. p.role .. "]" else ""), "SELECT", GREEN, function()
				selected = { userId = p.userId, name = p.name }
				show("Players")
			end)
		end
	end)
end

-- Event presets: the common event types from the spec, ready to start. Times use the server's clock.
local function presetEvent(id: string, name: string, hours: number, extra: { [string]: any }): { [string]: any }
	local now = math.floor(workspace:GetServerTimeNow())
	local ev: { [string]: any } = { id = id .. "-" .. now, name = name, start = now, ["end"] = now + hours * 3600, announce = name .. " has started!" }
	for k, v in extra do
		ev[k] = v
	end
	return ev
end

local function showEvents()
	clear()
	UiKit.row(list, "Start a boost weekend: 2x luck and 2x coins for 48 hours", "START", GREEN, function()
		call("event_upsert", { event = presetEvent("boost", "Boost Weekend", 48, { modifiers = { { kind = "luck", add = 100 }, { kind = "coins", mult = 2 } } }) }, function()
			show("Events")
		end)
	end)
	UiKit.row(list, "Slow chasers for 24 hours", "START", GREEN, function()
		call("event_upsert", { event = presetEvent("slow", "Slow Chasers", 24, { modifiers = { { kind = "chaser", mult = 0.8 } } }) }, function()
			show("Events")
		end)
	end)
	UiKit.row(list, "Enraged chasers for 6 hours", "START", ORANGE, function()
		call("event_upsert", { event = presetEvent("enraged", "Enraged Chasers", 6, { modifiers = { { kind = "chaser", mult = 1.3 }, { kind = "luck", add = 100 } } }) }, function()
			show("Events")
		end)
	end)
	UiKit.row(list, "Community goal: 200 parts for 500 coins each, 24 hours", "START", GREEN, function()
		call("event_upsert", { event = presetEvent("goal", "Community Goal", 24, { goal = { target = 200, rewardCoins = 500 } }) }, function()
			show("Events")
		end)
	end)
	UiKit.row(list, "Chaos: low gravity for 5 minutes", "START", ORANGE, function()
		call("event_upsert", { event = presetEvent("moon", "Moon Gravity", 5 / 60, { chaos = { kind = "gravity", value = 60 } }) }, function()
			show("Events")
		end)
	end)
	UiKit.row(list, "Chaos: coin rain, 1000 coins each", "RAIN", ORANGE, function()
		call("event_upsert", { event = presetEvent("rain", "Coin Rain", 1 / 60, { chaos = { kind = "coinRain", value = 1000 } }) }, function()
			show("Events")
		end)
	end)
	local json = inputRow("Custom JSON", "paste a full event record")
	UiKit.row(list, "Save the event pasted above", "SAVE", BLUE, function()
		local ok, ev = pcall(function()
			return HttpService:JSONDecode(json.Text)
		end)
		if ok and type(ev) == "table" then
			call("event_upsert", { event = ev }, function()
				show("Events")
			end)
		else
			status.Text = "NO: that is not valid JSON"
		end
	end)
	line("Existing events:")
	call("event_list", {}, function(ok, _, data)
		if not ok or type(data) ~= "table" then
			return
		end
		for _, ev in data do
			local label = string.format("%s  [%s]  %s -> %s  %s", ev.name, ev.status, timeText(ev.start), timeText(ev["end"]), ev.text)
			if ev.status ~= "ended" then
				UiKit.row(list, label, "STOP", RED, function()
					call("event_stop", { id = ev.id }, function()
						show("Events")
					end)
				end)
			else
				UiKit.row(list, label, nil)
			end
		end
	end)
end

local function showTuning()
	clear()
	call("tuning_get", {}, function(ok, _, data)
		if not ok or type(data) ~= "table" then
			return
		end
		for _, s in data do
			local changed = s.value ~= s.default
			if s.kind == "boolean" then
				UiKit.row(list, string.format("%s = %s%s", s.key, tostring(s.value), if changed then "  (changed)" else ""), if s.value then "TURN OFF" else "TURN ON", if s.value then ORANGE else GREEN, function()
					call("tuning_set", { key = s.key, value = not s.value }, function()
						show("Tuning")
					end)
				end)
			else
				UiKit.row(list, string.format("%s = %.2f%s", s.key, s.value, if changed then "  (changed)" else ""), "+0.1", GREEN, function()
					call("tuning_set", { key = s.key, value = math.floor((s.value + 0.1) * 100 + 0.5) / 100 }, function()
						show("Tuning")
					end)
				end)
				UiKit.row(list, "     " .. s.key .. " lower", "-0.1", ORANGE, function()
					call("tuning_set", { key = s.key, value = math.floor((s.value - 0.1) * 100 + 0.5) / 100 }, function()
						show("Tuning")
					end)
				end)
			end
		end
		UiKit.row(list, "Put every setting back to its default (owner)", "RESET ALL", RED, function()
			call("tuning_reset", { reason = "reset from the panel" }, function()
				show("Tuning")
			end)
		end)
	end)
end

local function showAudit()
	clear()
	call("audit", { count = 60 }, function(ok, _, data)
		if not ok or type(data) ~= "table" then
			return
		end
		for _, e in data do
			line(string.format("%s  %s (%s) %s%s  %s: %s", timeText(e.t), e.name, e.role, e.action, if e.target then " on " .. e.target else "", if e.ok then "ok" else "DENIED", e.result))
		end
		if #data == 0 then
			line("Nothing logged yet.")
		end
	end)
end

local function showMetrics()
	clear()
	UiKit.row(list, "Last hour on this server", "REFRESH", BLUE, function()
		show("Metrics")
	end)
	call("metrics", {}, function(ok, _, m)
		if not ok or type(m) ~= "table" then
			return
		end
		line(string.format("Covers %d minute(s). Runs: %d escaped, %d caught. Parts banked: %d", m.minutes, m.runsEscaped, m.runsCaught, m.partsBanked))
		for area, rate in m.catchRates do
			line(string.format("Catch rate in %s: %d%%", area, math.floor(rate * 100)))
		end
		line(string.format("Coins: %d earned, %d spent, balance %d", m.coinsEarned, m.coinsSpent, m.coinBalance))
		line(string.format("Trades %d, rebirths %d, purchases %d", m.trades, m.rebirths, m.purchases))
		line(string.format("Exploit flags %d, DataStore errors %d", m.exploitFlags, m.dataStoreErrors))
		local g = m.gauges
		if type(g) == "table" then
			line(string.format("Players %s, server fps %s", tostring(g.players), tostring(g.fps)))
		end
	end)
end

local function showExploits()
	clear()
	call("exploits", {}, function(ok, _, data)
		if not ok or type(data) ~= "table" then
			return
		end
		for _, e in data do
			UiKit.row(list, string.format("%s  %s (%d)  %s sev %d  %s", timeText(e.t), e.name, e.userId, e.kind, e.severity, e.detail), "SELECT", ORANGE, function()
				selected = { userId = e.userId, name = e.name }
				show("Players")
			end)
		end
		if #data == 0 then
			line("No exploit flags on this server.")
		end
	end)
end

local function showAnnounce()
	clear()
	local text = inputRow("Message", "shown to every player")
	UiKit.row(list, "Send to everyone on this server", "SEND", GREEN, function()
		call("announce", { text = text.Text })
	end)
end

local TABS: { { name: string, draw: () -> () } } = {
	{ name = "Players", draw = showPlayers },
	{ name = "Events", draw = showEvents },
	{ name = "Tuning", draw = showTuning },
	{ name = "Audit", draw = showAudit },
	{ name = "Metrics", draw = showMetrics },
	{ name = "Exploits", draw = showExploits },
	{ name = "Announce", draw = showAnnounce },
}
local current = "Players"
local tabButtons: { [string]: TextButton } = {}

function show(name: string)
	current = name
	for tabName, b in tabButtons do
		b.BackgroundColor3 = if tabName == name then ORANGE else Color3.fromRGB(110, 80, 60)
	end
	for _, t in TABS do
		if t.name == name then
			t.draw()
		end
	end
end

for _, t in TABS do
	local b = UiKit.button(tabRow, string.upper(t.name), UDim2.new(1 / #TABS, -6, 1, 0), Color3.fromRGB(110, 80, 60))
	tabButtons[t.name] = b
	b.Activated:Connect(function()
		selected = nil
		show(t.name)
	end)
end

openButton.Activated:Connect(function()
	panel.Visible = not panel.Visible
	if panel.Visible then
		show(current)
	end
end)
close.Activated:Connect(function()
	panel.Visible = false
end)

-- The panel only exists for people the server gave a role to. (This hides buttons; the server still checks everything.)
local function refresh()
	local role = player:GetAttribute("AdminRole")
	gui.Enabled = type(role) == "string"
	title.Text = "ADMIN  (" .. (if type(role) == "string" then role else "") .. ")"
end
player:GetAttributeChangedSignal("AdminRole"):Connect(refresh)
refresh()
