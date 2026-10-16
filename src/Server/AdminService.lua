--!strict
-- The admin command centre (spec section 8). The client panel is only a front end: every command arrives here, where
--   1. the role comes from the server's own record of who this player is (never from anything the client sends),
--   2. the role must be allowed to run that command (Shared/Admin),
--   3. the arguments are validated and cleaned (Shared/Admin.validate),
--   4. the action is written to the audit log BEFORE it runs: no record, no action (outside Studio),
--   5. it runs, and the result goes back to the panel.
-- Denied attempts are logged too. Inventory commands work on players who are online (their profile is loaded and
-- protected by the session lock); bans and unbans work on anyone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Admin = require(Shared:WaitForChild("Admin"))
local AuditLog = require(Shared:WaitForChild("AuditLog"))
local Config = require(Shared:WaitForChild("Config"))
local Events = require(Shared:WaitForChild("Events"))
local Profile = require(Shared:WaitForChild("Profile"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Rng = require(Shared:WaitForChild("Rng"))

local Analytics = require(script.Parent:WaitForChild("Analytics"))
local AuditLogger = require(script.Parent:WaitForChild("AuditLogger"))
local BanService = require(script.Parent:WaitForChild("BanService"))
local CraftService = require(script.Parent:WaitForChild("CraftService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local EventService = require(script.Parent:WaitForChild("EventService"))
local EventStore = require(script.Parent:WaitForChild("EventStore"))
local HomeService = require(script.Parent:WaitForChild("HomeService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local SnapshotService = require(script.Parent:WaitForChild("SnapshotService"))
local TradeLogger = require(script.Parent:WaitForChild("TradeLogger"))
local TradeService = require(script.Parent:WaitForChild("TradeService"))
local TuningService = require(script.Parent:WaitForChild("TuningService"))

local AdminService = {}

local request = Instance.new("RemoteEvent")
request.Name = "AdminRequest"
request.Parent = ReplicatedStorage
local result = Instance.new("RemoteEvent")
result.Name = "AdminResult"
result.Parent = ReplicatedStorage

local limiter = RateLimiter.new(Config.Admin.RateLimit.perSecond, Config.Admin.RateLimit.burst)
local roles: { [Player]: Admin.Role } = {}
local lastDenied: { [Player]: number } = {}
local grantRng = Rng.new(os.time() + 7)

-- Commands that only read; everything else must be logged before it runs.
local READ_ONLY: { [string]: boolean } = { players = true, inspect = true, audit = true, event_list = true, tuning_get = true, snapshots = true, trades = true }

local function roleOf(player: Player): Admin.Role
	return roles[player] or "none"
end

-- Works out a player's role once, when they join. Studio testers are owners so the panel can be tried out.
local function assignRole(player: Player)
	local rank: number? = nil
	if Config.Admin.GroupId ~= 0 then
		local ok, r = pcall(function()
			return player:GetRankInGroup(Config.Admin.GroupId)
		end)
		if ok then
			rank = r
		end
	end
	local role = Admin.roleFor(Config, player.UserId, rank)
	if role == "none" and RunService:IsStudio() and Config.Admin.StudioIsOwner then
		role = "owner"
	end
	roles[player] = role
	if role ~= "none" then
		player:SetAttribute("AdminRole", role) -- only tells the panel to appear; the server never reads it back
	end
end

local function reply(player: Player, rid: any, action: string, ok: boolean, message: string, data: any?)
	result:FireClient(player, { rid = rid, action = action, ok = ok, message = message, data = data })
end

local function audit(player: Player, action: string, targetId: number?, args: any, ok: boolean, message: string): boolean
	local entry = AuditLog.entry(os.time(), player.UserId, player.Name, roleOf(player), action, targetId, args, ok, message, game.JobId)
	return AuditLogger.write(entry)
end

-- Finds an online target and its loaded data, or says why not.
local function target(userId: number): (Player?, any, string?)
	local p = Players:GetPlayerByUserId(userId)
	if p == nil then
		return nil, nil, "that player is not on this server"
	end
	local data = PlayerData.get(p)
	if data == nil then
		return nil, nil, "that player's data is still loading"
	end
	if TradeService.isBusy(p) then
		return nil, nil, "that player is in a trade, try again in a moment"
	end
	return p, data, nil
end

local function refreshPlayer(p: Player)
	CraftService.push(p)
	EconomyService.publish(p)
	HomeService.refresh(p)
end

-- The commands ---------------------------------------------------------------------------------------------------------
type Handler = (admin: Player, a: { [string]: any }) -> (boolean, string, any?)

local handlers: { [string]: Handler } = {}

handlers.players = function()
	local list = {}
	for _, p in Players:GetPlayers() do
		local data = PlayerData.get(p)
		table.insert(list, {
			userId = p.UserId,
			name = p.Name,
			display = p.DisplayName,
			coins = if data then data.coins else 0,
			level = if data then Profile.level(Config.Speed, data) else 0,
			area = p:GetAttribute("Area") or "",
			role = roleOf(p),
		})
	end
	return true, #list .. " player(s)", list
end

handlers.inspect = function(_, a)
	-- Looking changes nothing, so a trade in progress does not matter here.
	local p = Players:GetPlayerByUserId(a.userId)
	local data = if p then PlayerData.get(p) else nil
	if p == nil or data == nil then
		return false, "that player is not on this server"
	end
	return true, "ok", { name = p.Name, summary = Admin.summary(Config, data) }
end

handlers.trades = function(_, a)
	return true, "ok", TradeLogger.history(a.userId)
end

handlers.kick = function(admin, a)
	if a.userId == admin.UserId then
		return false, "you cannot kick yourself"
	end
	BanService.kick(a.userId, a.reason)
	return true, "kicked"
end

handlers.announce = function(_, a)
	EventService.announce(a.text)
	return true, "announced"
end

handlers.audit = function(_, a)
	return true, "ok", AuditLogger.recent(a.count)
end

handlers.grant_coins = function(_, a)
	local p, data, why = target(a.userId)
	if p == nil then
		return false, why :: string
	end
	Admin.grantCoins(data, a.amount)
	refreshPlayer(p)
	return true, string.format("gave %d coins", a.amount)
end

handlers.remove_coins = function(_, a)
	local p, data, why = target(a.userId)
	if p == nil then
		return false, why :: string
	end
	local taken = Admin.removeCoins(data, a.amount)
	refreshPlayer(p)
	return true, string.format("removed %d coins", taken)
end

handlers.grant_part = function(_, a)
	local p, data, why = target(a.userId)
	if p == nil then
		return false, why :: string
	end
	Admin.grantPart(Config, data, a.partId, a.tier, a.count, grantRng, os.time())
	refreshPlayer(p)
	return true, string.format("gave %d x %s (tier %d)", a.count, a.partId, a.tier)
end

handlers.remove_part = function(_, a)
	local p, data, why = target(a.userId)
	if p == nil then
		return false, why :: string
	end
	if not Admin.removePart(data, a.uid) then
		return false, "that player has no such part"
	end
	refreshPlayer(p)
	return true, "removed"
end

handlers.ban = function(admin, a)
	if a.userId == admin.UserId then
		return false, "you cannot ban yourself"
	end
	if BanService.ban(a.userId, a.seconds, a.reason, admin.UserId) then
		return true, if a.seconds == 0 then "banned permanently" else string.format("banned for %d minute(s)", math.ceil(a.seconds / 60))
	end
	return false, "could not store the ban, nothing changed"
end

handlers.unban = function(_, a)
	if BanService.unban(a.userId) then
		return true, "unbanned"
	end
	return false, "could not remove the ban, try again"
end

handlers.snapshots = function(_, a)
	return true, "ok", SnapshotService.list(a.userId)
end

handlers.rollback = function(_, a)
	local p, data, why = target(a.userId)
	if p == nil then
		return false, why :: string
	end
	local snapshotData = SnapshotService.get(a.userId, a.index)
	if snapshotData == nil then
		return false, "no such snapshot"
	end
	-- Save the current state first, so a rollback can itself be undone.
	SnapshotService.take(p)
	if not Admin.rollback(Config, data, snapshotData) then
		return false, "that snapshot could not be restored"
	end
	PlayerData.saveNow(p)
	refreshPlayer(p)
	return true, "rolled back to snapshot " .. a.index
end

handlers.event_list = function()
	local now = os.time()
	local list = {}
	for _, ev in EventStore.list() do
		local status = if now < ev.start then "scheduled" elseif now >= ev["end"] then "ended" else "running"
		table.insert(list, { id = ev.id, name = ev.name, start = ev.start, ["end"] = ev["end"], status = status, text = Events.describe(ev), hasParts = ev.spawn ~= nil })
	end
	return true, #list .. " event(s)", list
end

handlers.event_upsert = function(_, a)
	local ok, why = EventStore.upsert(a.event)
	return ok, if ok then "event saved" else why
end

handlers.event_stop = function(_, a)
	local ev = EventStore.get(a.id)
	if ev == nil then
		return false, "no such event"
	end
	local now = os.time()
	if now >= ev["end"] then
		return false, "that event has already ended"
	end
	-- Ending it now keeps the record (and its parts) and just closes the window. A not-yet-started event is closed too.
	local stopped = table.clone(ev)
	stopped["end"] = math.max(ev.start + 1, now)
	stopped.start = math.min(ev.start, stopped["end"] - 1)
	local ok, why = EventStore.upsert(stopped)
	return ok, if ok then "event stopped" else why
end

handlers.event_delete = function(_, a)
	local ok, why = EventStore.remove(a.id)
	return ok, if ok then "event deleted" else why
end

handlers.tuning_get = function()
	return true, "ok", TuningService.list()
end

handlers.tuning_set = function(_, a)
	local ok, why = TuningService.set(a.key, a.value)
	return ok, if ok then (tostring(a.key) .. " set") else why
end

handlers.tuning_reset = function()
	local ok, why = TuningService.reset()
	return ok, if ok then "all settings reset to their defaults" else why
end

-- Entry point ------------------------------------------------------------------------------------------------------------
function AdminService.start()
	local function onPlayer(player: Player)
		task.spawn(assignRole, player)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		roles[player] = nil
		lastDenied[player] = nil
		limiter:forget(player)
	end)

	request.OnServerEvent:Connect(function(player: Player, rid: any, action: any, rawArgs: any)
		if type(action) ~= "string" or (type(rid) ~= "number" and type(rid) ~= "string") then
			return
		end
		if not limiter:allow(player, os.clock()) then
			return
		end
		local role = roleOf(player)

		-- Not allowed: refuse, and log it (at most every 10 seconds per player so probing cannot flood the log).
		if not Admin.can(role, action) then
			if os.clock() - (lastDenied[player] or -1e9) > 10 then
				lastDenied[player] = os.clock()
				audit(player, string.sub(action, 1, 30), nil, nil, false, "not allowed for role " .. role)
				Analytics.log(player, "AdminDenied", 1, { action = string.sub(action, 1, 30) })
			end
			reply(player, rid, action, false, "You are not allowed to do that.")
			return
		end

		local ok, args = Admin.validate(Config, action, rawArgs)
		if not ok then
			reply(player, rid, action, false, tostring(args))
			return
		end
		local targetId: number? = if type(args.userId) == "number" then args.userId else nil

		-- Log first. Commands that change things do not run unless the record is safely written.
		local written = audit(player, action, targetId, args, true, "requested")
		if not written and not READ_ONLY[action] then
			reply(player, rid, action, false, "The audit log is unavailable, so nothing was changed.")
			return
		end

		local handler = handlers[action]
		local okRun, success, message, data = pcall(handler, player, args)
		if not okRun then
			warn("[PetPartHunter] admin command " .. action .. " errored: " .. tostring(success))
			audit(player, action, targetId, args, false, "error")
			reply(player, rid, action, false, "That command failed, nothing was changed.")
			return
		end
		if not READ_ONLY[action] then
			-- The outcome is logged as well, so the log shows what actually happened and not only what was asked.
			audit(player, action, targetId, args, success :: boolean, tostring(message))
		end
		reply(player, rid, action, success :: boolean, tostring(message), data)
	end)
end

return AdminService
