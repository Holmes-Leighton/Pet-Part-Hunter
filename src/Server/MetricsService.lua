--!strict
-- The monitoring feed (spec section 9). Gameplay code reports events through Analytics.log; this service counts them
-- (Shared/Metrics), adds gauges (players, players per area, server health), and every minute posts a snapshot to your
-- dashboard backend (Config.Backend.MetricsUrl), where a tool such as Grafana can chart it. It also keeps the last hour in
-- memory for the admin panel. With no URL set nothing leaves the server, but the in-game numbers still work.
--
-- Payload (JSON): { v, t, job, seconds, events = { ["RunEscaped|area=Rare"] = { n, sum }, ... }, gauges = { ... } }

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Metrics = require(Shared:WaitForChild("Metrics"))

local Backend = require(script.Parent:WaitForChild("Backend"))

local MetricsService = {}

local state = Metrics.new(os.time())
local recent: { Metrics.Snapshot } = {}
local lastGauges: { [string]: any } = {}
local joinedAt: { [Player]: number } = {}
local frameSum, frameCount = 0.0, 0

function MetricsService.record(name: string, value: number?, fields: { [string]: any }?)
	Metrics.record(state, name, value, fields)
end

-- Numbers that are a level rather than a count: who is here and how healthy the server is.
local function gauges(): { [string]: any }
	local perArea: { [string]: number } = {}
	local inLobby = 0
	for _, p in Players:GetPlayers() do
		local area = p:GetAttribute("Area")
		if type(area) == "string" and area ~= "" then
			perArea[area] = (perArea[area] or 0) + 1
		else
			inLobby += 1
		end
	end
	local budgets: { [string]: number } = {}
	for name, kind in { get = Enum.DataStoreRequestType.GetAsync, set = Enum.DataStoreRequestType.SetIncrementAsync, update = Enum.DataStoreRequestType.UpdateAsync } do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(kind)
		end)
		if ok then
			budgets["datastore_" .. name] = budget
		end
	end
	local g: { [string]: any } = {
		players = #Players:GetPlayers(),
		lobby = inLobby,
		perArea = perArea,
		fps = if frameCount > 0 then math.floor(frameCount / frameSum * 10) / 10 else 0, -- server heartbeats per second
		budgets = budgets,
		uptime = math.floor(time()),
	}
	return g
end

-- Takes a snapshot, keeps it for the panel, and sends it to the backend.
local function flush()
	local snap = Metrics.snapshot(state, os.time())
	lastGauges = gauges()
	frameSum, frameCount = 0, 0
	table.insert(recent, snap)
	while #recent > Config.Monitoring.KeepSnapshots do
		table.remove(recent, 1)
	end
	Backend.post(Config.Backend.MetricsUrl, { v = 1, t = snap.t, job = game.JobId, seconds = snap.seconds, events = snap.events, gauges = lastGauges }, "metrics")
end

-- What the admin panel shows: the last hour's headline numbers and the latest gauges.
function MetricsService.summary(): { [string]: any }
	local hour = Metrics.rollup(recent)
	local catchRates: { [string]: number } = {}
	local areaNames = {}
	for _, a in Config.Areas :: any do
		table.insert(areaNames, a.name)
	end
	for _, name in areaNames do
		local rate = Metrics.catchRate(hour, name)
		if rate then
			catchRates[name] = math.floor(rate * 100) / 100
		end
	end
	local function ev(key: string): number
		local c = hour.events[key]
		return if c then c.n else 0
	end
	local function sum(key: string): number
		local c = hour.events[key]
		return if c then math.floor(c.sum) else 0
	end
	return {
		minutes = math.floor(hour.seconds / 60),
		catchRates = catchRates,
		coinsEarned = sum("CoinsEarned"),
		coinsSpent = sum("CoinsSpent"),
		coinBalance = math.floor(Metrics.coinBalance(hour)),
		runsEscaped = ev("RunEscaped"),
		runsCaught = ev("RunCaught"),
		partsBanked = sum("RunEscaped"),
		trades = ev("TradeCompleted"),
		rebirths = ev("Rebirth"),
		purchases = ev("ProductPurchased") + ev("PassPurchased"),
		exploitFlags = ev("ExploitFlag"),
		dataStoreErrors = ev("DataStoreError"),
		gauges = lastGauges,
	}
end

function MetricsService.start()
	Backend.errorHook = function(_)
		MetricsService.record("DataStoreError", 1, { kind = "backend" })
	end
	Players.PlayerAdded:Connect(function(player)
		joinedAt[player] = os.clock()
		MetricsService.record("PlayerJoined")
	end)
	for _, p in Players:GetPlayers() do
		joinedAt[p] = os.clock()
	end
	Players.PlayerRemoving:Connect(function(player)
		local start = joinedAt[player]
		joinedAt[player] = nil
		if start then
			MetricsService.record("SessionSeconds", os.clock() - start) -- the sum divided by the count is the average session
		end
	end)
	RunService.Heartbeat:Connect(function(dt)
		frameSum += dt
		frameCount += 1
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Monitoring.FlushSeconds)
			flush()
		end
	end)
	game:BindToClose(function()
		flush() -- the last partial interval is sent before the server closes
	end)
end

return MetricsService
