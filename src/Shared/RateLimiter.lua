--!strict
-- Token-bucket limiter for remote events (spec section 9): `burst` calls at once, refilled at `perSecond`.
-- Keyed by anything (the server uses the Player); the clock is passed in so tests can control time.

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable({} :: { perSecond: number, burst: number, buckets: { [any]: { tokens: number, at: number } } }, RateLimiter))

function RateLimiter.new(perSecond: number, burst: number): RateLimiter
	return setmetatable({ perSecond = perSecond, burst = burst, buckets = {} }, RateLimiter)
end

function RateLimiter.allow(self: RateLimiter, key: any, now: number): boolean
	local b = self.buckets[key]
	if b == nil then
		b = { tokens = self.burst, at = now }
		self.buckets[key] = b
	end
	b.tokens = math.min(self.burst, b.tokens + (now - b.at) * self.perSecond)
	b.at = now
	if b.tokens >= 1 then
		b.tokens -= 1
		return true
	end
	return false
end

function RateLimiter.forget(self: RateLimiter, key: any)
	self.buckets[key] = nil
end

return RateLimiter
