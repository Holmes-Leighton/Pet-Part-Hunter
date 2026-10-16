--!strict
-- Monitoring numbers (spec section 9): what to track so the economy, difficulty and paid areas can be watched. Pure
-- counters, so the aggregation is tested; the server's MetricsService feeds events in, adds gauges (players, server
-- health), and posts a snapshot to your dashboard backend every minute.
--
-- Everything is a count and a sum per event name, plus the same split by one dimension where the event has one:
--   RunEscaped|area=Rare     -> how many runs escaped in Rare, and how many parts they carried (n and sum)
--   CoinsEarned|source=SellParts, CoinsSpent|sink=BagUpgrade, ProductPurchased|product=LuckBoost, ExploitFlag|kind=speed
-- Catch rate and escape rate per area, coins earned against spent per hour, drops against collections and pass conversion
-- all come from these keys.

local Metrics = {}

export type Cell = { n: number, sum: number }
export type State = { cells: { [string]: Cell }, started: number }
export type Snapshot = { t: number, seconds: number, events: { [string]: Cell } }

-- The fields that split an event into sub-keys. Free text never becomes a key, so the number of keys stays small.
local DIMENSIONS = { "area", "source", "sink", "product", "kind", "action", "lopsided", "trade" }
local MAX_KEYS = 400

function Metrics.new(now: number): State
	return { cells = {}, started = now }
end

local function bump(state: State, key: string, value: number)
	local cell = state.cells[key]
	if cell == nil then
		-- A hard cap on keys, so a bug that invents a new key per event cannot grow memory without bound.
		local count = 0
		for _ in state.cells do
			count += 1
		end
		if count >= MAX_KEYS then
			return
		end
		cell = { n = 0, sum = 0 }
		state.cells[key] = cell
	end
	cell.n += 1
	cell.sum += value
end

function Metrics.record(state: State, name: string, value: number?, fields: { [string]: any }?)
	local v = value or 1
	if v ~= v or v == math.huge or v == -math.huge then
		v = 0
	end
	bump(state, name, v)
	if fields then
		for _, dim in DIMENSIONS do
			local x = fields[dim]
			if x ~= nil and (type(x) == "string" or type(x) == "number" or type(x) == "boolean") then
				local text = string.sub(tostring(x), 1, 30)
				bump(state, name .. "|" .. dim .. "=" .. text, v)
			end
		end
	end
end

-- Takes what has been counted since the last snapshot and starts a fresh interval.
function Metrics.snapshot(state: State, now: number): Snapshot
	local events: { [string]: Cell } = {}
	for key, cell in state.cells do
		events[key] = { n = cell.n, sum = cell.sum }
	end
	local snap: Snapshot = { t = now, seconds = math.max(1, now - state.started), events = events }
	state.cells = {}
	state.started = now
	return snap
end

-- Adds up a run of snapshots (for example the last hour), with the total time they cover.
function Metrics.rollup(snaps: { Snapshot }): Snapshot
	local events: { [string]: Cell } = {}
	local seconds, last = 0, 0
	for _, s in snaps do
		seconds += s.seconds
		last = math.max(last, s.t)
		for key, cell in s.events do
			local c = events[key]
			if c == nil then
				c = { n = 0, sum = 0 }
				events[key] = c
			end
			c.n += cell.n
			c.sum += cell.sum
		end
	end
	return { t = last, seconds = seconds, events = events }
end

-- Per-hour rate of an event's count or sum over a snapshot.
function Metrics.perHour(snap: Snapshot, key: string, useSum: boolean?): number
	local cell = snap.events[key]
	if cell == nil or snap.seconds <= 0 then
		return 0
	end
	return (if useSum then cell.sum else cell.n) * 3600 / snap.seconds
end

-- The share of runs in an area that ended in a catch (spec: tune chaser speed from catch and escape rates).
function Metrics.catchRate(snap: Snapshot, area: string): number?
	local caught = snap.events["RunCaught|area=" .. area]
	local escaped = snap.events["RunEscaped|area=" .. area]
	local c, e = if caught then caught.n else 0, if escaped then escaped.n else 0
	if c + e == 0 then
		return nil
	end
	return c / (c + e)
end

-- Coins earned minus coins spent over the snapshot: the inflation signal (spec: "catch inflation early").
function Metrics.coinBalance(snap: Snapshot): number
	local earned = snap.events["CoinsEarned"]
	local spent = snap.events["CoinsSpent"]
	return (if earned then earned.sum else 0) - (if spent then spent.sum else 0)
end

return Metrics
