--!strict
-- Thin wrapper over AnalyticsService (spec section 9). Logging must never break gameplay, so every call is pcall'd.
-- In Studio it also prints, so events can be checked while playtesting.

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local MetricsService = require(script.Parent:WaitForChild("MetricsService"))

local Analytics = {}

-- Logs a custom event, e.g. Analytics.log(player, "Rebirth", 3, { Speed = 4050 }).
function Analytics.log(player: Player, name: string, value: number?, fields: { [string]: any }?)
	MetricsService.record(name, value, fields) -- every analytics event also feeds the monitoring counters
	if RunService:IsStudio() then
		print(string.format("[Analytics] %s %s value=%s", player.Name, name, tostring(value)))
	end
	pcall(function()
		(AnalyticsService :: any):LogCustomEvent(player, name, value or 1, fields)
	end)
end

return Analytics
