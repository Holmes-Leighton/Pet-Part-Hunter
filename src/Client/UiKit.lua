--!strict
-- Small helpers for the chunky candy-style UI (spec section 3, "Look and feel"): dark outlines, rounded corners,
-- big touch targets. Used by the home UI; the older HUD scripts build their widgets inline.

local UiKit = {}

UiKit.DARK = Color3.fromRGB(20, 14, 10)

function UiKit.round(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

function UiKit.outline(inst: Instance, thickness: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = UiKit.DARK
	s.Parent = inst
end

function UiKit.button(parent: Instance, text: string, size: UDim2, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Size = size
	b.BackgroundColor3 = color
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextStrokeTransparency = 0
	b.Font = Enum.Font.GothamBlack
	b.TextScaled = true
	b.Parent = parent
	UiKit.round(b, 10)
	UiKit.outline(b, 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
	pad.Parent = b
	return b
end

function UiKit.label(parent: Instance, text: string, size: UDim2): TextLabel
	local t = Instance.new("TextLabel")
	t.Size = size
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.4
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Parent = parent
	return t
end

-- A scrolling vertical list. Returns the frame to parent rows into.
function UiKit.list(parent: Instance, position: UDim2, size: UDim2): ScrollingFrame
	local list = Instance.new("ScrollingFrame")
	list.BackgroundColor3 = Color3.fromRGB(46, 30, 22)
	list.Position = position
	list.Size = size
	list.ScrollBarThickness = 8
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = parent
	UiKit.round(list, 10)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop = UDim.new(0, 8), UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = list
	return list
end

-- One row in a list: a label and an optional button on the right.
function UiKit.row(list: Instance, labelText: string, buttonText: string?, buttonColor: Color3?, onClick: (() -> ())?): TextButton?
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, 48)
	f.BackgroundColor3 = Color3.fromRGB(86, 60, 44)
	f.Parent = list
	UiKit.round(f, 8)
	local t = UiKit.label(f, labelText, UDim2.new(1, -150, 1, -8))
	t.Position = UDim2.fromOffset(10, 4)
	if buttonText then
		local b = UiKit.button(f, buttonText, UDim2.fromOffset(130, 40), buttonColor or Color3.fromRGB(60, 150, 80))
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -6, 0.5, 0)
		if onClick then
			b.Activated:Connect(onClick)
		end
		return b
	end
	return nil
end

return UiKit
