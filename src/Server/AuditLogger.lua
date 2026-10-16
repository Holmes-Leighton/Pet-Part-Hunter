--!strict
-- Stores the admin audit log (spec section 8). Entries are appended to one list per UTC day in a DataStore, optionally
-- sent to your backend, and printed to the server output (denied attempts as warnings). State-changing admin commands are
-- logged BEFORE they run, and if the log cannot be written (outside Studio) the command does not run: there must never
-- be an admin action without a record.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AuditLog = require(Shared:WaitForChild("AuditLog"))
local Config = require(Shared:WaitForChild("Config"))

local Backend = require(script.Parent:WaitForChild("Backend"))

local AuditLogger = {}

local recent: { AuditLog.Entry } = {}
local RECENT_MAX = 200

-- Writes an entry. Returns true when it is safely stored (or when there is nowhere to store it, in Studio).
function AuditLogger.write(entry: AuditLog.Entry): boolean
	table.insert(recent, entry)
	if #recent > RECENT_MAX then
		table.remove(recent, 1)
	end
	local line = AuditLog.summary(entry)
	if entry.ok then
		print("[PetPartHunter] " .. line)
	else
		warn("[PetPartHunter] " .. line)
	end
	Backend.post(Config.Backend.AuditLogUrl, entry, "audit entry")

	local s = Backend.store(Config.Backend.AuditStore)
	if s == nil then
		return Backend.available(Config.Backend.AuditStore)
	end
	local ok = Backend.retry(3, function()
		s:UpdateAsync(AuditLog.dayKey(entry.t), function(old: any)
			return AuditLog.append(old, entry, Config.Admin.AuditMaxPerDay)
		end)
	end)
	return ok or RunService:IsStudio()
end

-- The newest entries first, from this server's memory and, if needed, today's stored list.
function AuditLogger.recent(count: number): { AuditLog.Entry }
	local out: { AuditLog.Entry } = {}
	for i = #recent, 1, -1 do
		table.insert(out, recent[i])
		if #out >= count then
			return out
		end
	end
	local s = Backend.store(Config.Backend.AuditStore)
	if s then
		local ok, list = pcall(function()
			return s:GetAsync(AuditLog.dayKey(os.time()))
		end)
		if ok and type(list) == "table" then
			local have: { [string]: boolean } = {}
			for _, e in out do
				have[e.t .. e.admin .. e.action] = true
			end
			for i = #list, 1, -1 do
				local e = list[i]
				if not have[e.t .. e.admin .. e.action] then
					table.insert(out, e)
					if #out >= count then
						break
					end
				end
			end
		end
	end
	return out
end

return AuditLogger
