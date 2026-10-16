--!strict
-- Runs events on this server (spec section 8). EventStore holds the records; this module decides what is active right
-- now, announces starts and ends, applies the modifiers, counts the community goal, runs chaos effects, and tells the
-- clients what is on (for the banner) and which event parts exist (so they can name and show them).
--
--   * modifiers (luck, coins, speed gain, chaser speed) are read by the other services through EventService.mods(),
--   * Main is told through `onChange` so it can change spawn pools and build or remove event areas,
--   * a community goal counts parts escaped on this server; when it completes, everyone who helped shares the reward.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Events = require(Shared:WaitForChild("Events"))

local Analytics = require(script.Parent:WaitForChild("Analytics"))
local EventStore = require(script.Parent:WaitForChild("EventStore"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local EventService = {}

local NORMAL_GRAVITY = 196.2
local FRESH_SECONDS = 120 -- a chaos "burst" only fires if the event just started, not when a server joins mid-event

local active: { Events.Event } = {}
local mods: Events.Mods = Events.aggregate({})
local signature = ""
local goals: { [string]: Events.GoalState } = {}
local fired: { [string]: boolean } = {}
local notifyRemote: RemoteEvent? = nil
local onChange: (({ Events.Event }, Events.Mods, { Events.Event }, { Events.Event }) -> ())? = nil
local lastGoalPublish = 0
local goalDirty = false

function EventService.mods(): Events.Mods
	return mods
end

function EventService.active(): { Events.Event }
	return active
end

-- Tells every player something (the same short-message channel the game already uses).
function EventService.announce(text: string)
	if notifyRemote then
		notifyRemote:FireAllClients(text)
	end
end

-- Replication ----------------------------------------------------------------------------------------------------------
local function publishActive()
	local out = {}
	for _, ev in active do
		local goal = if ev.goal then { target = ev.goal.target, progress = (goals[ev.id] or Events.newGoal()).progress } else nil
		table.insert(out, { id = ev.id, name = ev.name, endsAt = ev["end"], text = Events.describe(ev), goal = goal })
	end
	ReplicatedStorage:SetAttribute("ActiveEvents", HttpService:JSONEncode(out))
end

-- Every known event's exclusive parts, so clients can register them (their pets and index need the names and rarities).
local function publishParts()
	local out: { [string]: any } = {}
	for _, ev in EventStore.list() do
		if ev.spawn then
			out[ev.id] = { tradable = ev.tradable == true, parts = ev.spawn.parts }
		end
	end
	ReplicatedStorage:SetAttribute("EventParts", HttpService:JSONEncode(out))
end

-- Effects ---------------------------------------------------------------------------------------------------------------
local function startEffects(ev: Events.Event, now: number)
	EventService.announce(ev.announce or (ev.name .. " has started!"))
	local anyone = Players:GetPlayers()[1]
	if anyone then
		Analytics.log(anyone, "EventStarted", 1, { event = ev.id })
	end
	if ev.goal and goals[ev.id] == nil then
		goals[ev.id] = Events.newGoal()
	end
	local chaos = ev.chaos
	if chaos and chaos.kind == "gravity" then
		Workspace.Gravity = chaos.value :: number
	elseif chaos and chaos.kind == "coinRain" and not fired[ev.id] and now - ev.start < FRESH_SECONDS then
		fired[ev.id] = true
		for _, p in Players:GetPlayers() do
			local data = PlayerData.get(p)
			if data then
				data.coins += chaos.value :: number
				data.stats.coinsEarned += chaos.value :: number
			end
		end
		EventService.announce(string.format("Coin rain! Everyone gets %d coins!", chaos.value :: number))
	end
end

local function endEffects(ev: Events.Event)
	EventService.announce(ev.name .. " has ended.")
	if ev.chaos and ev.chaos.kind == "gravity" then
		Workspace.Gravity = NORMAL_GRAVITY
	end
	goals[ev.id] = nil
end

-- Community goal ---------------------------------------------------------------------------------------------------------
-- Call when a player escapes with parts. Counts towards every active event that has a goal.
function EventService.recordParts(player: Player, count: number)
	for _, ev in active do
		local goal = ev.goal
		local state = goals[ev.id]
		if goal and state then
			goalDirty = true
			if Events.addProgress(goal, state, player.UserId, count) then
				EventService.announce(string.format("Community goal reached for %s! Everyone who helped gets %d coins!", ev.name, goal.rewardCoins))
				for userId, coins in Events.rewards(goal, state) do
					local p = Players:GetPlayerByUserId(userId)
					local data = if p then PlayerData.get(p) else nil
					if p and data then
						data.coins += coins
						data.stats.coinsEarned += coins
						Analytics.log(p, "GoalReward", coins, { event = ev.id })
					end
				end
			end
		end
	end
end

-- Main loop -----------------------------------------------------------------------------------------------------------------
local function refresh()
	local now = os.time()
	local newActive = Events.active(EventStore.list(), now)
	local newSig = Events.signature(newActive)
	if newSig == signature then
		return
	end
	local before: { [string]: boolean } = {}
	for _, ev in active do
		before[ev.id] = true
	end
	local after: { [string]: boolean } = {}
	for _, ev in newActive do
		after[ev.id] = true
	end
	local started, ended = {}, {}
	for _, ev in newActive do
		if not before[ev.id] then
			table.insert(started, ev)
		end
	end
	for _, ev in active do
		if not after[ev.id] then
			table.insert(ended, ev)
		end
	end
	local previous = active
	active = newActive
	signature = newSig
	mods = Events.aggregate(active)
	for _, ev in ended do
		endEffects(ev)
	end
	for _, ev in started do
		startEffects(ev, now)
	end
	publishActive()
	if onChange then
		onChange(active, mods, started, ended)
	end
	local _ = previous
end

function EventService.start(notify: RemoteEvent, change: ({ Events.Event }, Events.Mods, { Events.Event }, { Events.Event }) -> ())
	notifyRemote = notify
	onChange = change
	EventStore.onChanged(function()
		publishParts()
		signature = "?" -- force a re-check against the new list
		refresh()
	end)
	task.spawn(function()
		EventStore.waitReady(60)
		publishParts()
		publishActive()
		while true do
			refresh()
			-- Goal progress is published a few times a minute at most, not on every part.
			if goalDirty and os.clock() - lastGoalPublish > 5 then
				goalDirty = false
				lastGoalPublish = os.clock()
				publishActive()
			end
			task.wait(1)
		end
	end)
end

return EventService
