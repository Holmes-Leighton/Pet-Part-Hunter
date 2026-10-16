--!strict
-- Trading between players (spec section 5), on the server. The rules are in Shared/Trade (unit tested); this connects
-- them to remotes. The client only asks: invite, answer, change its offer, lock, confirm or cancel. The server checks
-- who may trade, validates every offer against the player's real inventory, and runs the swap itself.
--
-- Safety, in order, when both players have confirmed:
--   1. the whole trade is re-validated (a part sold mid-trade cancels it, nothing moves),
--   2. its record is written to the backend log (TradeLogger); if that fails the trade does NOT happen,
--   3. the items are swapped in one step and both players' data is saved straight away.
-- Every ending is logged: completed, cancelled, expired and failed trades alike. While a player is in a trade window
-- or an invite is open they cannot sell, merge, build pets or go on a run, so the offered items cannot change.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Crafting = require(Shared:WaitForChild("Crafting"))
local Profile = require(Shared:WaitForChild("Profile"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Trade = require(Shared:WaitForChild("Trade"))
local TradeLog = require(Shared:WaitForChild("TradeLog"))
local Recovery = require(Shared:WaitForChild("TradeRecovery"))

local Analytics = require(script.Parent:WaitForChild("Analytics"))
local AntiExploit = require(script.Parent:WaitForChild("AntiExploit"))
local CraftService = require(script.Parent:WaitForChild("CraftService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local TradeLogger = require(script.Parent:WaitForChild("TradeLogger"))

local TradeService = {}

local state = Instance.new("RemoteEvent")
state.Name = "TradeState"
state.Parent = ReplicatedStorage
local request = Instance.new("RemoteEvent")
request.Name = "TradeRequest"
request.Parent = ReplicatedStorage

local limiter = RateLimiter.new(Config.RateLimit.Trade.perSecond, Config.RateLimit.Trade.burst)

type Active = { session: Trade.Session, startedEpoch: number, executing: boolean }
type Invite = { from: Player, expires: number }

local sessions: { [Player]: Active } = {} -- both players of a trade map to the same Active
local invites: { [Player]: Invite } = {} -- keyed by the player who was invited
local lastTrade: { [number]: number } = {} -- userId -> os.clock of their last completed trade
local completedTimes: { [number]: { number } } = {} -- userId -> epoch seconds of completed trades, for the volume flag
local inRunCheck: (Player) -> boolean = function()
	return false
end
local notifyRemote: RemoteEvent? = nil
local counter = 0
local recovering: { [Player]: boolean } = {} -- players whose interrupted trades are still being finished

local function tell(player: Player, text: string)
	if notifyRemote then
		notifyRemote:FireClient(player, text)
	end
end

-- True while the player is in a trade window or has a trade request pending. Other services refuse to change their
-- inventory in that time.
function TradeService.isBusy(player: Player): boolean
	if sessions[player] ~= nil or invites[player] ~= nil then
		return true
	end
	for _, inv in invites do
		if inv.from == player then
			return true
		end
	end
	return false
end

-- Views for the UI -------------------------------------------------------------------------------------------------------
local function itemView(item: Crafting.Item): any
	local stats = Crafting.itemStats(Config, item :: any)
	return { uid = item.uid, id = item.id, tier = item.tier, stats = stats, value = Trade.partValue(Config, item) }
end

local function offerView(data: any, offer: Trade.Offer): any
	local parts, pets = {}, {}
	for _, uid in offer.parts do
		for _, it in data.parts do
			if it.uid == uid then
				table.insert(parts, itemView(it))
			end
		end
	end
	for _, uid in offer.pets do
		for _, pet in data.pets do
			if pet.uid == uid then
				local slots = {}
				for socket, item in pet.slots do
					slots[socket] = { id = item.id, tier = item.tier }
				end
				table.insert(pets, { uid = pet.uid, slots = slots, stats = Crafting.petStats(Config, pet), value = Trade.petValue(Config, pet) })
			end
		end
	end
	return { parts = parts, pets = pets }
end

local function datasFor(s: Trade.Session): { [number]: any }?
	local pa, pb = Players:GetPlayerByUserId(s.a.userId), Players:GetPlayerByUserId(s.b.userId)
	local da, db = pa and PlayerData.get(pa), pb and PlayerData.get(pb)
	if da == nil or db == nil then
		return nil
	end
	return { [s.a.userId] = da, [s.b.userId] = db }
end

local function push(player: Player, active: Active)
	local s = active.session
	local other = Trade.other(s, player.UserId)
	local datas = datasFor(s)
	if other == nil or datas == nil then
		return
	end
	local now = os.clock()
	local ev = Trade.evaluate(Config, s, datas)
	state:FireClient(player, {
		kind = "state",
		id = s.id,
		status = s.state,
		reason = s.reason,
		me = { userId = player.UserId },
		other = { userId = other.userId, name = other.name },
		mine = offerView(datas[player.UserId], s.offers[player.UserId]),
		theirs = offerView(datas[other.userId], s.offers[other.userId]),
		value = { mine = ev.value[player.UserId], theirs = ev.value[other.userId] },
		lopsided = ev.lopsided,
		iAmGiver = ev.lopsided and ev.giver == player.UserId,
		lockedMine = s.locked[player.UserId] == true,
		lockedTheirs = s.locked[other.userId] == true,
		confirmedMine = s.confirmed[player.UserId] == true,
		confirmedTheirs = s.confirmed[other.userId] == true,
		wait = Trade.confirmWait(Config, s, now),
		maxItems = Config.Trade.MaxItemsPerSide,
	})
end

local function pushBoth(active: Active)
	for _, party in { active.session.a, active.session.b } do
		local p = Players:GetPlayerByUserId(party.userId)
		if p then
			push(p, active)
		end
	end
end

-- Ending a trade ------------------------------------------------------------------------------------------------------
-- Builds and writes the record of a window that ended without a swap. Never blocks the players for long.
local function logEnded(active: Active, flags: { string }?)
	local s = active.session
	local datas = datasFor(s)
	local ev: Trade.Evaluation = { value = { [s.a.userId] = 0, [s.b.userId] = 0 }, lopsided = false, giver = nil, ratio = 1 }
	local gave: { [number]: Trade.Gave } = { [s.a.userId] = { parts = {}, pets = {} }, [s.b.userId] = { parts = {}, pets = {} } }
	if datas then
		ev = Trade.evaluate(Config, s, datas)
		gave = { [s.a.userId] = Trade.gave(s, s.a.userId, datas[s.a.userId]), [s.b.userId] = Trade.gave(s, s.b.userId, datas[s.b.userId]) }
	end
	TradeLogger.write(TradeLog.build(s, gave, ev, active.startedEpoch, os.time(), game.JobId, flags))
end

local function release(active: Active)
	for _, party in { active.session.a, active.session.b } do
		local p = Players:GetPlayerByUserId(party.userId)
		if p then
			sessions[p] = nil
		end
	end
end

local function closeTrade(active: Active, status: string, reason: string)
	local s = active.session
	if s.state ~= "open" then
		return
	end
	Trade.close(s, status, reason, os.clock())
	task.spawn(function()
		logEnded(active, nil)
	end)
	pushBoth(active) -- tells both clients the window is closed, and why
	release(active)
	for _, party in { s.a, s.b } do
		local p = Players:GetPlayerByUserId(party.userId)
		if p then
			tell(p, "Trade " .. status .. ": " .. reason)
		end
	end
end

-- Both players confirmed: validate, log, swap, save.
local function complete(active: Active)
	local s = active.session
	if active.executing or not Trade.ready(s) then
		return
	end
	active.executing = true
	local datas = datasFor(s)
	if datas == nil then
		active.executing = false
		closeTrade(active, "failed", "a player's data was not available")
		return
	end

	-- Preflight: the swap must be able to succeed before anything is recorded as completed.
	for _, party in { s.a, s.b } do
		local offer = s.offers[party.userId]
		local ok, why = Trade.checkOffer(Config, datas[party.userId], offer.parts, offer.pets)
		if not ok then
			active.executing = false
			closeTrade(active, "failed", party.name .. ": " .. why)
			return
		end
	end

	-- The record is written first. A preview copy carries the "completed" outcome the record will describe.
	local ev = Trade.evaluate(Config, s, datas)
	local gave = { [s.a.userId] = Trade.gave(s, s.a.userId, datas[s.a.userId]), [s.b.userId] = Trade.gave(s, s.b.userId, datas[s.b.userId]) }
	local flags: { string } = {}
	for _, party in { s.a, s.b } do
		local times = completedTimes[party.userId] or {}
		completedTimes[party.userId] = times
		table.insert(times, os.time())
		if TradeLog.volumeFlag(times, os.time(), Config.Trade.VolumePerHour) then
			table.insert(flags, "volume_" .. party.userId)
		end
		table.remove(times) -- the real entry is added only if the swap goes ahead
	end
	local preview = table.clone(s)
	preview.state = "completed"
	preview.reason = "completed"
	local record = TradeLog.build(preview, gave, ev, active.startedEpoch, os.time(), game.JobId, flags)
	local key = TradeLog.key(record)

	-- Step 1: a durable note of intent in both profiles. If the server dies from here on, the next load of either
	-- profile finds this note and finishes or drops the trade by itself (Shared/TradeRecovery).
	local pa, pb = Players:GetPlayerByUserId(s.a.userId), Players:GetPlayerByUserId(s.b.userId)
	if pa == nil or pb == nil then
		active.executing = false
		closeTrade(active, "failed", "a player left")
		return
	end
	Recovery.begin(datas[s.a.userId], s.id, key)
	Recovery.begin(datas[s.b.userId], s.id, key)
	if not (PlayerData.saveNow(pa) and PlayerData.saveNow(pb)) then
		Recovery.discard(datas[s.a.userId], s.id)
		Recovery.discard(datas[s.b.userId], s.id)
		active.executing = false
		closeTrade(active, "failed", "could not save, nothing was traded")
		return
	end

	-- Step 2: the commit point. Once this record exists, the trade has happened as far as recovery is concerned.
	if not TradeLogger.write(record) then
		Recovery.discard(datas[s.a.userId], s.id)
		Recovery.discard(datas[s.b.userId], s.id)
		active.executing = false
		closeTrade(active, "failed", "trading is temporarily unavailable, nothing was traded")
		return
	end

	-- Unusual trade volume goes to the exploit log too (spec section 9), so it is reviewed alongside everything else.
	for _, flag in flags do
		local volumeUser = string.match(flag, "^volume_(%d+)$")
		if volumeUser then
			local p = Players:GetPlayerByUserId(tonumber(volumeUser) :: number)
			AntiExploit.flagUser(tonumber(volumeUser) :: number, if p then p.Name else volumeUser, "trade_volume", "more than " .. Config.Trade.VolumePerHour .. " trades in an hour", 2)
		end
	end

	-- The log wait yielded: re-fetch the data and re-check before moving anything.
	-- A "failed" record with the same time and the id + "_f" supersedes the completed one: recovery reads it and
	-- drops the pending note instead of finishing the trade.
	local function supersede(reason: string)
		local failed = table.clone(record)
		failed.id = record.id .. "_f"
		failed.status = "failed"
		failed.reason = reason .. "; supersedes " .. record.id
		TradeLogger.write(failed)
		for _, party in { s.a, s.b } do
			local p = Players:GetPlayerByUserId(party.userId)
			local d = if p then PlayerData.get(p) else nil
			if d then
				Recovery.discard(d, s.id)
			end
		end
	end
	local fresh = datasFor(s)
	if fresh == nil or s.state ~= "open" then
		active.executing = false
		supersede("a player left before the swap")
		closeTrade(active, "failed", "a player left before the swap")
		return
	end
	local ok, why = Trade.execute(Config, s, fresh, os.clock())
	if not ok then
		active.executing = false
		supersede("swap rejected: " .. why)
		closeTrade(active, "failed", why)
		return
	end
	-- Step 3: both profiles now show the trade as applied (and no longer pending); save them straight away.
	Recovery.settle(fresh[s.a.userId], s.id)
	Recovery.settle(fresh[s.b.userId], s.id)

	-- Done. Cooldowns, volume tracking, saving, and telling everyone.
	for _, party in { s.a, s.b } do
		lastTrade[party.userId] = os.clock()
		table.insert(completedTimes[party.userId], os.time())
	end
	pushBoth(active)
	release(active)
	for _, party in { s.a, s.b } do
		local p = Players:GetPlayerByUserId(party.userId)
		if p then
			task.spawn(function()
				PlayerData.saveNow(p) -- a trade is never left only in memory
			end)
			CraftService.push(p)
			Analytics.log(p, "TradeCompleted", ev.value[party.userId] or 0, { lopsided = tostring(ev.lopsided) })
			tell(p, "Trade complete!")
		end
	end
end

-- Requests ----------------------------------------------------------------------------------------------------------------
local function eligibility(player: Player): (boolean, string)
	local data = PlayerData.get(player)
	if data == nil then
		return false, "your data is still loading"
	end
	if recovering[player] then
		return false, "an interrupted trade is being finished, try again in a moment"
	end
	return Trade.eligible(Config, player.AccountAge, Profile.level(Config.Speed, data))
end

-- Crash recovery -----------------------------------------------------------------------------------------------------
-- A profile that loads with a pending trade was left mid-trade by a server crash (or a player leaving mid-swap). The
-- trade record is the commit point: no completed record means the trade never happened, so the note is dropped; a
-- completed record that was not superseded means it did, so this player's side is applied now. Idempotent and
-- independent per player (see Shared/TradeRecovery). Until it is settled the player cannot start a new trade.
local function recoverPlayer(player: Player, data: any)
	if #Recovery.pending(data) == 0 then
		return
	end
	recovering[player] = true
	task.spawn(function()
		for attempt = 1, 20 do
			local unresolved, changed, finished = false, false, false
			for _, entry in Recovery.pending(data) do
				local rec, ok = TradeLogger.get(entry.key)
				if not ok then
					unresolved = true -- could not read the log: never guess, try again later
				elseif rec == nil or not Recovery.isCommitted(rec) then
					Recovery.discard(data, entry.id) -- never committed: nothing to do
					changed = true
				else
					local superseded, ok2 = TradeLogger.get(TradeLog.supersededKey(rec))
					if not ok2 then
						unresolved = true
					elseif superseded ~= nil then
						Recovery.discard(data, entry.id) -- committed, then the swap was rejected: it never happened
						changed = true
					else
						local result = Recovery.recover(data, rec, player.UserId, os.time())
						warn(string.format("[PetPartHunter] trade %s recovered for %s: %s", entry.id, player.Name, result))
						Analytics.log(player, "TradeRecovered", 1, { trade = entry.id })
						changed, finished = true, true
					end
				end
			end
			if changed then
				PlayerData.saveNow(player)
				CraftService.push(player)
			end
			if finished then
				tell(player, "A trade that was interrupted by a server problem has now been completed.")
			end
			if not unresolved or player.Parent == nil then
				break
			end
			task.wait(30)
		end
		recovering[player] = nil
	end)
end

function TradeService.start(inRun: (Player) -> boolean, notify: RemoteEvent)
	inRunCheck = inRun
	notifyRemote = notify

	PlayerData.onLoaded(function(player, data)
		recoverPlayer(player, data)
	end)

	local function dropInvitesOf(player: Player)
		invites[player] = nil
		for target, inv in invites do
			if inv.from == player then
				invites[target] = nil
				state:FireClient(target, { kind = "invite_gone" })
			end
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		limiter:forget(player)
		local active = sessions[player]
		if active then
			closeTrade(active, "cancelled", player.DisplayName .. " left the game")
		end
		dropInvitesOf(player)
	end)

	-- Expire idle windows and unanswered requests.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			local seen: { [Active]: boolean } = {}
			for _, active in sessions do
				if not seen[active] then
					seen[active] = true
					if Trade.expired(Config, active.session, now) and not active.executing then
						closeTrade(active, "expired", "no activity")
					else
						-- Keeps the confirm countdown moving on the clients.
						if Trade.bothLocked(active.session) and Trade.confirmWait(Config, active.session, now) > 0 then
							pushBoth(active)
						end
					end
				end
			end
			for target, inv in invites do
				if now > inv.expires then
					invites[target] = nil
					state:FireClient(target, { kind = "invite_gone" })
					tell(inv.from, "Your trade request timed out.")
				end
			end
		end
	end)

	request.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any)
		if type(action) ~= "string" or not limiter:allow(player, os.clock()) then
			return
		end
		local data = PlayerData.get(player)
		if data == nil then
			return
		end

		if action == "Invite" then
			if sessions[player] or TradeService.isBusy(player) then
				tell(player, "Finish your current trade first.")
				return
			end
			if inRunCheck(player) then
				tell(player, "Not right now: finish your run first!")
				return
			end
			local target = if type(a) == "number" then Players:GetPlayerByUserId(a) else nil
			if target == nil or target == player then
				return
			end
			local ok, why = eligibility(player)
			if not ok then
				tell(player, "You can't trade yet: " .. why)
				return
			end
			local tok = eligibility(target)
			if not tok or inRunCheck(target) or TradeService.isBusy(target) then
				tell(player, target.DisplayName .. " can't trade right now.")
				return
			end
			local waited = os.clock() - (lastTrade[player.UserId] or -1e9)
			if waited < Config.Trade.CooldownSeconds then
				tell(player, string.format("Wait %d more seconds before your next trade.", math.ceil(Config.Trade.CooldownSeconds - waited)))
				return
			end
			invites[target] = { from = player, expires = os.clock() + Config.Trade.InviteSeconds }
			state:FireClient(target, { kind = "invite", fromUserId = player.UserId, fromName = player.DisplayName, seconds = Config.Trade.InviteSeconds })
			tell(player, "Trade request sent to " .. target.DisplayName)
			return
		end

		if action == "Respond" then
			local inv = invites[player]
			if inv == nil then
				return
			end
			invites[player] = nil
			state:FireClient(player, { kind = "invite_gone" })
			if a ~= true then
				tell(inv.from, player.DisplayName .. " declined your trade request.")
				return
			end
			local from = inv.from
			if from.Parent == nil or sessions[from] or sessions[player] or inRunCheck(from) or inRunCheck(player) then
				tell(player, "That trade is no longer available.")
				return
			end
			if os.clock() - (lastTrade[player.UserId] or -1e9) < Config.Trade.CooldownSeconds then
				tell(player, "You traded very recently. Wait a little.")
				return
			end
			counter += 1
			local id = string.format("%s-%d", string.sub(game.JobId ~= "" and game.JobId or "studio", 1, 8), counter) .. "-" .. os.time()
			local s = Trade.new(Config, id, { userId = from.UserId, name = from.DisplayName }, { userId = player.UserId, name = player.DisplayName }, os.clock())
			local active: Active = { session = s, startedEpoch = os.time(), executing = false }
			sessions[from] = active
			sessions[player] = active
			pushBoth(active)
			return
		end

		local active = sessions[player]
		if active == nil or active.executing then
			return
		end
		local s = active.session
		local now = os.clock()

		if action == "SetOffer" then
			local ok, why = Trade.setOffer(Config, s, player.UserId, data, a, b, now)
			if not ok then
				tell(player, "Cannot offer that: " .. why)
			end
		elseif action == "Lock" then
			local ok, why = Trade.lock(s, player.UserId, now)
			if not ok then
				tell(player, why)
			end
		elseif action == "Unlock" then
			Trade.unlock(s, player.UserId, now)
		elseif action == "Confirm" then
			local datas = datasFor(s)
			if datas == nil then
				return
			end
			local ev = Trade.evaluate(Config, s, datas)
			local ok, why = Trade.confirm(Config, s, player.UserId, a == true, ev, now)
			if not ok then
				tell(player, why)
			end
		elseif action == "Cancel" then
			closeTrade(active, "cancelled", player.DisplayName .. " cancelled")
			return
		else
			return
		end
		pushBoth(active)
		if Trade.ready(s) then
			complete(active)
		end
	end)
end

return TradeService
