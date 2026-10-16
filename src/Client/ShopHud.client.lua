--!strict
-- Coins and the Robux shop (spec section 7). Always shows your coins and any running boosts; the SHOP button opens
-- passes, area access and boosts/coin packs. Buying goes through Roblox's own purchase prompts, and the server
-- grants the goods only after verifying the purchase (and announces it to everyone). Items whose ID is still 0 in
-- Config show "SOON". Parts, chaser skips and escape skips are never sold: the hunt stays earned (spec).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterShopHud"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

-- Coins and boosts (top right, under the banked-parts line) ---------------------------------------------------------
local coinLabel = UiKit.label(gui, "", UDim2.fromOffset(240, 34))
coinLabel.AnchorPoint = Vector2.new(1, 0)
coinLabel.Position = UDim2.new(0.985, 0, 0.075, 0)
coinLabel.TextXAlignment = Enum.TextXAlignment.Right
coinLabel.TextColor3 = Color3.fromRGB(255, 220, 90)
coinLabel.Font = Enum.Font.GothamBlack
local boostLabel = UiKit.label(gui, "", UDim2.fromOffset(240, 24))
boostLabel.AnchorPoint = Vector2.new(1, 0)
boostLabel.Position = UDim2.new(0.985, 0, 0.075, 36)
boostLabel.TextXAlignment = Enum.TextXAlignment.Right
boostLabel.TextColor3 = Color3.fromRGB(160, 255, 170)

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

local function refreshStatus()
	coinLabel.Text = "COINS " .. commas((player:GetAttribute("Coins") :: number?) or 0)
	local bits = {}
	local luckUntil = (player:GetAttribute("LuckUntil") :: number?) or 0
	local left = luckUntil - workspace:GetServerTimeNow()
	if left > 0 then
		table.insert(bits, string.format("LUCK %d:%02d", math.floor(left / 60), math.floor(left % 60)))
	end
	local insurance = (player:GetAttribute("Insurance") :: number?) or 0
	if insurance > 0 then
		table.insert(bits, "INSURANCE x" .. insurance)
	end
	boostLabel.Text = table.concat(bits, "   ")
end
player:GetAttributeChangedSignal("Coins"):Connect(refreshStatus)
player:GetAttributeChangedSignal("Insurance"):Connect(refreshStatus)
player:GetAttributeChangedSignal("LuckUntil"):Connect(refreshStatus)
RunService.Heartbeat:Connect(function()
	if (player:GetAttribute("LuckUntil") :: number?) ~= nil then
		refreshStatus() -- keeps the luck countdown ticking
	end
end)

-- The shop ------------------------------------------------------------------------------------------------------------
type Entry = { kind: "pass" | "product" | "furniture", key: string, desc: string }

local TABS: { [string]: { Entry } } = {
	Passes = {
		{ kind = "pass", key = "DoubleSpeed", desc = "Doubles the Speed you gain" },
		{ kind = "pass", key = "DoubleCoins", desc = "Doubles coins from selling" },
		{ kind = "pass", key = "ExtraBag1", desc = "+2 bag slots" },
		{ kind = "pass", key = "ExtraBag2", desc = "+4 bag slots (replaces +2)" },
		{ kind = "pass", key = "ExtraPetSlots", desc = "Equip up to 6 pets" },
		{ kind = "pass", key = "HouseExpansion", desc = "+" .. Config.House.ExpansionBonus .. " house items" },
	},
	Areas = {
		{ kind = "pass", key = "Area_SuperRare", desc = "Early access (or reach Rebirth 2)" },
		{ kind = "pass", key = "Area_Legendary", desc = "Early access (or reach Rebirth 4)" },
		{ kind = "pass", key = "Area_Mythic", desc = "Early access (or reach Rebirth 6)" },
		{ kind = "pass", key = "AllAreas", desc = "All three, discounted" },
	},
	Boosts = {
		{ kind = "product", key = "LuckBoost", desc = "Better stat rolls for 30 minutes" },
		{ kind = "product", key = "Insurance", desc = "Keep your bag if caught (one use)" },
		{ kind = "product", key = "BagSlot", desc = "+1 bag slot. Buy as many as you like, no limit" },
		{ kind = "product", key = "CoinPackSmall", desc = "+2,000 coins" },
		{ kind = "product", key = "CoinPackMedium", desc = "+12,000 coins" },
		{ kind = "product", key = "CoinPackLarge", desc = "+60,000 coins" },
	},
}
-- Premium furniture: one Robux product per item, straight from the furniture catalog.
TABS.Furniture = {}
for _, f in Config.Furniture :: any do
	if f.premium then
		table.insert(TABS.Furniture, { kind = "furniture", key = f.id, desc = string.format("%s, %dx%d. Robux-only, not tradable", f.surface, f.w, f.d) })
	end
end
local TAB_ORDER = { "Passes", "Areas", "Boosts", "Furniture" }
local currentTab = "Passes"
local prices: { [string]: number } = {} -- "pass:key" / "product:key" -> Robux, filled in from Roblox

local shopButton = UiKit.button(gui, "SHOP", UDim2.fromOffset(130, 60), Color3.fromRGB(230, 170, 40))
shopButton.AnchorPoint = Vector2.new(1, 0.5)
shopButton.Position = UDim2.new(0.97, 0, 0.5, -100)

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.78, 0.8)
panel.BackgroundColor3 = Color3.fromRGB(70, 48, 34)
panel.Visible = false
panel.Parent = gui
UiKit.round(panel, 16)
UiKit.outline(panel, 4)
local title = UiKit.label(panel, "SHOP", UDim2.new(1, -90, 0, 36))
title.Position = UDim2.fromOffset(16, 8)
local close = UiKit.button(panel, "X", UDim2.fromOffset(44, 44), Color3.fromRGB(220, 50, 50))
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
local list = UiKit.list(panel, UDim2.fromOffset(12, 108), UDim2.new(1, -24, 1, -126))

local render: () -> ()

local function idOf(e: Entry): number
	if e.kind == "furniture" then
		for _, f in Config.Furniture :: any do
			if f.id == e.key then
				return f.product
			end
		end
		return 0
	end
	local source: any = if e.kind == "pass" then Config.Passes else Config.Products
	local v = source[e.key]
	return if type(v) == "table" then v.id else v
end

local function nameOf(e: Entry): string
	if e.kind == "furniture" then
		for _, f in Config.Furniture :: any do
			if f.id == e.key then
				return f.name
			end
		end
	end
	local n = if e.kind == "pass" then (Config.PassNames :: any)[e.key] else (Config.Products :: any)[e.key].name
	local trimmed = string.gsub(n, "^the ", "")
	trimmed = string.gsub(trimmed, "^a ", "")
	return trimmed
end

-- Looks the Robux price up from Roblox so it is always right, then redraws.
local function fetchPrice(e: Entry)
	local id = idOf(e)
	local cacheKey = e.kind .. ":" .. e.key
	if id == 0 or prices[cacheKey] ~= nil then
		return
	end
	prices[cacheKey] = -1 -- looking up
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, if e.kind == "pass" then Enum.InfoType.GamePass else Enum.InfoType.Product)
		end)
		if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
			prices[cacheKey] = info.PriceInRobux
			if panel.Visible then
				render()
			end
		end
	end)
end

function render()
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for _, b in tabRow:GetChildren() :: { any } do
		if b:IsA("TextButton") then
			b.BackgroundColor3 = if b.Name == currentTab then Color3.fromRGB(230, 130, 40) else Color3.fromRGB(110, 80, 60)
		end
	end
	for _, e in TABS[currentTab] do
		fetchPrice(e)
		local id = idOf(e)
		local owned = e.kind == "pass" and player:GetAttribute("Pass_" .. e.key) == true
		local price = prices[e.kind .. ":" .. e.key]
		local label = nameOf(e) .. "  -  " .. e.desc
		if owned then
			UiKit.row(list, label, "OWNED", Color3.fromRGB(70, 120, 70), nil)
		elseif id == 0 then
			UiKit.row(list, label, "SOON", Color3.fromRGB(90, 90, 90), nil)
		else
			UiKit.row(list, label, if price and price >= 0 then "R$ " .. price else "BUY", Color3.fromRGB(60, 150, 80), function()
				if e.kind == "pass" then
					MarketplaceService:PromptGamePassPurchase(player, id)
				else
					MarketplaceService:PromptProductPurchase(player, id)
				end
			end)
		end
	end
end

for _, name in TAB_ORDER do
	local b = UiKit.button(tabRow, string.upper(name), UDim2.new(1 / #TAB_ORDER, -6, 1, 0), Color3.fromRGB(110, 80, 60))
	b.Name = name
	b.Activated:Connect(function()
		currentTab = name
		render()
	end)
end
shopButton.Activated:Connect(function()
	panel.Visible = not panel.Visible
	if panel.Visible then
		render()
	end
end)
close.Activated:Connect(function()
	panel.Visible = false
end)

-- A bought pass shows OWNED straight away.
for key in Config.Passes :: any do
	player:GetAttributeChangedSignal("Pass_" .. key):Connect(function()
		if panel.Visible then
			render()
		end
	end)
end

local function refreshVisibility()
	local running = player:GetAttribute("RunState") == "running"
	shopButton.Visible = not running
	if running then
		panel.Visible = false
	end
end
player:GetAttributeChangedSignal("RunState"):Connect(refreshVisibility)
refreshVisibility()
refreshStatus()
