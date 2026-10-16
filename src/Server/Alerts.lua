--!strict
-- Alerts for serious events (spec section 9): "a webhook to a relay for serious events, such as a player gaining a huge
-- number of parts in one run". Discord often blocks Roblox's servers, so Config.Backend.AlertUrl should point at a small
-- relay of your own that forwards to Discord or wherever you like. Each kind of alert is sent at most once per cooldown so
-- a flood of the same event cannot flood your channel. Always printed to the server output as well.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Backend = require(script.Parent:WaitForChild("Backend"))

local Alerts = {}

local lastSent: { [string]: number } = {}

-- kind: a short stable name ("exploit_duplicate_parts"); message: one line for a human; details: small JSON-safe table.
function Alerts.send(kind: string, message: string, details: { [string]: any }?)
	local now = os.clock()
	if now - (lastSent[kind] or -1e9) < Config.Monitoring.AlertCooldownSeconds then
		return
	end
	lastSent[kind] = now
	warn("[PetPartHunter] ALERT " .. kind .. ": " .. message)
	Backend.post(Config.Backend.AlertUrl, { kind = kind, message = string.sub(message, 1, 300), details = details or {}, job = game.JobId, t = os.time() }, "alert " .. kind)
end

return Alerts
