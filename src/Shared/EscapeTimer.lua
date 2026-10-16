--!strict
-- Standing in a teleport-out point for HoldSeconds triggers the escape; leaving or being interrupted resets it
-- (spec section 4). Once it completes it stays done until reset.

local EscapeTimer = {}
EscapeTimer.__index = EscapeTimer

export type EscapeTimer = typeof(setmetatable({} :: { hold: number, elapsed: number, done: boolean }, EscapeTimer))

function EscapeTimer.new(holdSeconds: number): EscapeTimer
	assert(holdSeconds > 0, "hold time must be positive")
	return setmetatable({ hold = holdSeconds, elapsed = 0, done = false }, EscapeTimer)
end

-- inside: the player is standing in a teleport point. interrupted: something (the chaser) broke the hold this tick.
-- Returns progress 0..1.
function EscapeTimer.update(self: EscapeTimer, dt: number, inside: boolean, interrupted: boolean): number
	if self.done then
		return 1
	end
	if not inside or interrupted then
		self.elapsed = 0
		return 0
	end
	self.elapsed = math.min(self.elapsed + dt, self.hold)
	if self.elapsed >= self.hold then
		self.done = true
	end
	return self.elapsed / self.hold
end

function EscapeTimer.progress(self: EscapeTimer): number
	return self.elapsed / self.hold
end

function EscapeTimer.isDone(self: EscapeTimer): boolean
	return self.done
end

function EscapeTimer.reset(self: EscapeTimer)
	self.elapsed = 0
	self.done = false
end

return EscapeTimer
