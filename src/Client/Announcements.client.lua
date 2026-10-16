--!strict
-- Shows purchase announcements sent by the server (spec section 7): a line in the chat and a short notification
-- banner at the top of the screen. Your own purchases read "You bought ..." and are highlighted. The text comes from
-- Shared/Announce, which escapes player names, so nothing a player types can change how the line looks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Announce = require(Shared:WaitForChild("Announce"))
local Config = require(Shared:WaitForChild("Config"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local remote = ReplicatedStorage:WaitForChild("PurchaseAnnounce") :: RemoteEvent

local localPlayer = Players.LocalPlayer

local gui = Instance.new("ScreenGui")
gui.Name = "PetPartHunterAnnouncements"
gui.ResetOnSpawn = false
gui.DisplayOrder = 20
gui.Parent = localPlayer:WaitForChild("PlayerGui")

local stack = Instance.new("Frame")
stack.Name = "Toasts"
stack.AnchorPoint = Vector2.new(0.5, 0)
stack.Position = UDim2.new(0.5, 0, 0, 70)
stack.Size = UDim2.fromOffset(380, 220)
stack.BackgroundTransparency = 1
stack.Parent = gui
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = stack

local order = 0

-- A banner that slides in, waits, then fades. Older banners are removed once more than MaxToasts are showing.
local function toast(text: string, isSelf: boolean, userId: number)
	order += 1
	local f = Instance.new("Frame")
	f.LayoutOrder = order
	f.Size = UDim2.fromOffset(360, 48)
	f.BackgroundColor3 = if isSelf then Color3.fromRGB(70, 140, 60) else Color3.fromRGB(60, 42, 30)
	f.BackgroundTransparency = 0.1
	f.Parent = stack
	UiKit.round(f, 12)
	UiKit.outline(f, 2)

	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.fromOffset(40, 40)
	icon.Position = UDim2.fromOffset(4, 4)
	icon.BackgroundTransparency = 1
	icon.Parent = f
	UiKit.round(icon, 20)
	task.spawn(function()
		-- The buyer's avatar; if it cannot load the banner still works.
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		if ok and icon.Parent then
			icon.Image = image
		end
	end)

	local label = UiKit.label(f, text, UDim2.new(1, -56, 1, -8))
	label.Position = UDim2.fromOffset(50, 4)

	-- Slide in from above.
	f.Position = UDim2.fromOffset(0, -60)
	TweenService:Create(f, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(0, 0) }):Play()

	local banners = {}
	for _, c in stack:GetChildren() do
		if c:IsA("Frame") then
			table.insert(banners, c)
		end
	end
	table.sort(banners, function(a: Frame, b: Frame)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #banners > Config.Announce.MaxToasts do
		table.remove(banners, 1):Destroy()
	end

	task.delay(Config.Announce.ToastSeconds, function()
		if f.Parent then
			TweenService:Create(f, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			task.wait(0.45)
			f:Destroy()
		end
	end)
end

-- The chat line: the modern chat service if it is on, otherwise the legacy chat.
local function chat(rich: string, plain: string)
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		local channels = TextChatService:FindFirstChild("TextChannels")
		local general = channels and channels:FindFirstChild("RBXGeneral") :: TextChannel?
		if general then
			pcall(function()
				general:DisplaySystemMessage(rich)
			end)
		end
	else
		pcall(function()
			StarterGui:SetCore("ChatMakeSystemMessage", { Text = "[SHOP] " .. plain, Color = Color3.fromRGB(255, 211, 77), Font = Enum.Font.GothamBold })
		end)
	end
end

remote.OnClientEvent:Connect(function(info: any)
	if type(info) ~= "table" or type(info.name) ~= "string" or type(info.what) ~= "string" or type(info.userId) ~= "number" then
		return
	end
	local isSelf = info.userId == localPlayer.UserId
	local what = string.sub(info.what, 1, 80)
	chat(Announce.chatLine(info.name, what, isSelf), Announce.plain(info.name, what, isSelf))
	toast(Announce.plain(info.name, what, isSelf), isSelf, info.userId)
end)
