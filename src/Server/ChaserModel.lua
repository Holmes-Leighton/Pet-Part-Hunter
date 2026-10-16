--!strict
-- The visible placeholder creature for a chaser: a glowing body with eyes. Position comes from the Chaser logic.

local ChaserModel = {}

function ChaserModel.create(owner: string, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "Chaser_" .. owner

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Ball
	body.Size = Vector3.new(6, 6, 6)
	body.Color = Color3.fromRGB(170, 20, 60)
	body.Material = Enum.Material.Neon
	body.Anchored = true
	body.CanCollide = false
	body.CanTouch = false
	body.CanQuery = false
	body.Parent = model

	for _, side in { -1, 1 } do
		local eye = Instance.new("Part")
		eye.Name = "Eye"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(1.4, 1.4, 1.4)
		eye.Color = Color3.fromRGB(255, 255, 255)
		eye.Material = Enum.Material.Neon
		eye.Anchored = true
		eye.CanCollide = false
		eye.CanTouch = false
		eye.CanQuery = false
		eye.CFrame = body.CFrame * CFrame.new(side * 1.3, 0.8, -2.6)
		eye.Parent = model
	end

	model.PrimaryPart = body
	model.Parent = parent
	return model
end

-- Place the creature above the ground at (x, z), turned to face its target.
function ChaserModel.place(model: Model, x: number, z: number, faceX: number, faceZ: number, t: number)
	local pos = Vector3.new(x, 3.5 + math.sin(t * 6) * 0.4, z)
	local look = Vector3.new(faceX, pos.Y, faceZ)
	if (look - pos).Magnitude < 0.1 then
		look = pos + Vector3.new(0, 0, -1)
	end
	model:PivotTo(CFrame.lookAt(pos, look))
end

return ChaserModel
