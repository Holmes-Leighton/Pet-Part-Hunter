--!strict
-- Bans (spec section 8: kick, ban). A ban record, and whether it still applies. Pure logic; the server's BanService stores
-- records and kicks banned players on every server.

local Bans = {}

export type Ban = {
	userId: number,
	untilTime: number, -- epoch seconds the ban ends; 0 means permanent
	reason: string,
	by: number, -- the admin's user id
	t: number, -- when it was issued
}

-- Builds a ban. `seconds` of 0 is permanent.
function Bans.new(userId: number, seconds: number, reason: string, by: number, now: number): Ban
	return { userId = userId, untilTime = if seconds <= 0 then 0 else now + seconds, reason = string.sub(reason, 1, 120), by = by, t = now }
end

function Bans.isActive(ban: any, now: number): boolean
	if type(ban) ~= "table" or type(ban.untilTime) ~= "number" then
		return false
	end
	return ban.untilTime == 0 or now < ban.untilTime
end

-- The message a banned player sees when they are removed.
function Bans.message(ban: Ban, now: number): string
	local length = if ban.untilTime == 0 then "permanently" else string.format("for another %d minute(s)", math.max(1, math.ceil((ban.untilTime - now) / 60)))
	return string.format("You are banned %s. Reason: %s", length, ban.reason)
end

return Bans
