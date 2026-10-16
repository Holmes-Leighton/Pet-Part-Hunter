--!strict
-- Where events live (spec section 8). Events are data records in a DataStore, not code, so an admin can create, change
-- or stop one without shipping an update. Servers read the list when they start, refresh it on a timer, and learn about
-- admin changes immediately through MessagingService.
--
-- Every record is validated on the way in and again on the way out (Shared/Events), because the list is edited by people.
-- Event parts are registered in the part table as soon as an event is known, and stay registered after it ends, so a
-- player's saved event parts always load. For that reason an event with exclusive parts can be stopped but never deleted.
-- Nothing else here depends on player data, so PlayerData can wait for this store to be ready before loading profiles.

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Events = require(Shared:WaitForChild("Events"))

local EventStore = {}

local TOPIC = "PPH_Events"
local KEY = "list"
local MAX_EVENTS = 100

local events: { Events.Event } = {}
local rev = 0
local ready = false
local store: DataStore? = nil
local listeners: { () -> () } = {}
local readySignal = Instance.new("BindableEvent")

local function getStore(): DataStore?
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Config.Backend.EventStore)
		end)
		if ok then
			store = result
		end
	end
	return store
end

local function notifyChanged()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

-- Replaces the in-memory list with a validated copy of `raw`, registering every event's parts.
local function apply(raw: any, newRev: number)
	local list: { Events.Event } = {}
	if type(raw) == "table" then
		for _, rec in raw do
			local ok, why = Events.validate(Config, rec)
			if ok then
				local pOk, pWhy = Events.registerParts(rec)
				if pOk then
					table.insert(list, rec)
				else
					warn("[PetPartHunter] event " .. tostring(rec.id) .. " skipped: " .. pWhy)
				end
			else
				warn("[PetPartHunter] event " .. tostring(type(rec) == "table" and rec.id) .. " is invalid and was ignored: " .. why)
			end
		end
	end
	events = list
	rev = newRev
	notifyChanged()
end

-- Reads the stored list. Returns true when the read worked (an empty store counts as a successful, empty read).
local function fetch(): boolean
	local s = getStore()
	if s == nil then
		return RunService:IsStudio() -- nothing stored in Studio without API access; production treats it as a failure
	end
	local ok, value = pcall(function()
		return s:GetAsync(KEY)
	end)
	if not ok then
		return false
	end
	if type(value) == "table" then
		if value.rev ~= rev or not ready then
			apply(value.events, value.rev or 0)
		end
	elseif not ready then
		apply({}, 0)
	end
	return true
end

function EventStore.ready(): boolean
	return ready
end

-- Waits up to `timeout` seconds for the first successful read. Returns whether the events are loaded.
function EventStore.waitReady(timeout: number): boolean
	if ready then
		return true
	end
	local done = false
	local conn = readySignal.Event:Connect(function()
		done = true
	end)
	local deadline = os.clock() + timeout
	while not done and not ready and os.clock() < deadline do
		task.wait(0.1)
	end
	conn:Disconnect()
	return ready
end

function EventStore.list(): { Events.Event }
	return events
end

function EventStore.get(id: string): Events.Event?
	for _, ev in events do
		if ev.id == id then
			return ev
		end
	end
	return nil
end

-- Called whenever the list changes (an admin edit, or a refresh that found a newer list).
function EventStore.onChanged(fn: () -> ())
	table.insert(listeners, fn)
end

local function publish()
	pcall(function()
		MessagingService:PublishAsync(TOPIC, { rev = rev })
	end)
end

-- Creates or replaces an event. Validates it, registers its parts, stores it, and tells the other servers.
function EventStore.upsert(ev: any): (boolean, string)
	local ok, why = Events.validate(Config, ev)
	if not ok then
		return false, why
	end
	local pOk, pWhy = Events.registerParts(ev)
	if not pOk then
		return false, pWhy
	end
	local existing = EventStore.get(ev.id)
	if existing == nil and #events >= MAX_EVENTS then
		return false, "too many events stored, delete an old one first"
	end
	local s = getStore()
	if s then
		local saved = pcall(function()
			s:UpdateAsync(KEY, function(old: any)
				local list: { any } = if type(old) == "table" and type(old.events) == "table" then old.events else {}
				local replaced = false
				for i, rec in list do
					if type(rec) == "table" and rec.id == ev.id then
						list[i] = ev
						replaced = true
					end
				end
				if not replaced then
					table.insert(list, ev)
				end
				return { rev = (if type(old) == "table" and type(old.rev) == "number" then old.rev else 0) + 1, events = list }
			end)
		end)
		if not saved then
			return false, "could not save the event, try again"
		end
		fetch()
		publish()
	elseif RunService:IsStudio() then
		-- No DataStore in Studio: keep it in memory so the panel can still be tried out.
		local list = table.clone(events)
		local replaced = false
		for i, rec in list do
			if rec.id == ev.id then
				list[i] = ev
				replaced = true
			end
		end
		if not replaced then
			table.insert(list, ev)
		end
		apply(list, rev + 1)
	else
		return false, "event storage is unavailable"
	end
	return true, "ok"
end

-- Deletes an event record. Events with exclusive parts are refused: players may hold those parts, so the definition
-- must stay. Stop them instead (set the end time to now).
function EventStore.remove(id: string): (boolean, string)
	local ev = EventStore.get(id)
	if ev == nil then
		return false, "no such event"
	end
	if ev.spawn ~= nil then
		return false, "events with exclusive parts cannot be deleted, stop it instead"
	end
	local s = getStore()
	if s then
		local saved = pcall(function()
			s:UpdateAsync(KEY, function(old: any)
				local list: { any } = {}
				if type(old) == "table" and type(old.events) == "table" then
					for _, rec in old.events do
						if not (type(rec) == "table" and rec.id == id) then
							table.insert(list, rec)
						end
					end
				end
				return { rev = (if type(old) == "table" and type(old.rev) == "number" then old.rev else 0) + 1, events = list }
			end)
		end)
		if not saved then
			return false, "could not save, try again"
		end
		fetch()
		publish()
	else
		local list: { Events.Event } = {}
		for _, rec in events do
			if rec.id ~= id then
				table.insert(list, rec)
			end
		end
		apply(list, rev + 1)
	end
	return true, "ok"
end

-- Start-up: read until it works, then refresh on a timer and on admin messages from other servers.
task.spawn(function()
	local attempt = 0
	while not fetch() do
		attempt += 1
		warn("[PetPartHunter] could not read events (attempt " .. attempt .. "), retrying")
		task.wait(math.min(5 * attempt, 30))
	end
	ready = true
	readySignal:Fire()

	pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function()
			task.spawn(fetch)
		end)
	end)
	while true do
		task.wait(60)
		fetch()
	end
end)

return EventStore
