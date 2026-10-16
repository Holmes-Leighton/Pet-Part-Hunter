--!strict
-- Small deterministic random generator (LCG) so mazes and spawns can be reproduced from a seed in tests.

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

local MOD = 4294967296

function Rng.new(seed: number): Rng
	return setmetatable({ state = math.floor(seed) % MOD }, Rng)
end

-- Next float in [0, 1).
function Rng.next(self: Rng): number
	self.state = (self.state * 1664525 + 1013904223) % MOD
	return self.state / MOD
end

-- Integer in [min, max], inclusive.
function Rng.int(self: Rng, min: number, max: number): number
	return min + math.floor(self:next() * (max - min + 1))
end

-- In-place Fisher-Yates shuffle.
function Rng.shuffle<T>(self: Rng, list: { T })
	for i = #list, 2, -1 do
		local j = self:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

return Rng
