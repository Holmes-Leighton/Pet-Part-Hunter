--!strict
-- The admin audit log (spec section 8: "every admin action is recorded with who, what, target and time"). Pure functions
-- that build the entries and manage the per-day lists they are stored in. The server's AuditLogger stores them; denied
-- attempts are logged too, because someone probing admin commands is worth knowing about.

local AuditLog = {}

export type Entry = {
	v: number,
	t: number, -- epoch seconds
	admin: number, -- user id of who did it
	name: string,
	role: string,
	action: string,
	target: number?, -- user id acted on, when there is one
	args: { [string]: any }, -- the cleaned arguments (never raw client input)
	ok: boolean,
	result: string, -- what happened, or why it was refused
	job: string,
}

AuditLog.VERSION = 1

-- Keeps only plain, small values, so an entry is always JSON-safe and cannot grow without bound.
local function scrub(v: any, depth: number): any
	local t = type(v)
	if t == "string" then
		return string.sub(v, 1, 200)
	elseif t == "boolean" then
		return v
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return 0
		end
		return v
	elseif t == "table" and depth < 3 then
		local out: { [any]: any } = {}
		local n = 0
		for k, x in v do
			n += 1
			if n > 20 then
				break
			end
			if type(k) == "string" or type(k) == "number" then
				out[if type(k) == "number" then k else string.sub(k, 1, 40)] = scrub(x, depth + 1)
			end
		end
		return out
	end
	return nil
end

function AuditLog.entry(t: number, admin: number, name: string, role: string, action: string, target: number?, args: any, ok: boolean, result: string, job: string): Entry
	return {
		v = AuditLog.VERSION,
		t = t,
		admin = admin,
		name = string.sub(name, 1, 40),
		role = role,
		action = action,
		target = target,
		args = if type(args) == "table" then scrub(args, 0) else {},
		ok = ok,
		result = string.sub(result, 1, 200),
		job = job,
	}
end

-- One list per UTC day, so a day's log is a single read: "A20261016".
function AuditLog.dayKey(t: number): string
	return "A" .. os.date("!%Y%m%d", t)
end

-- Adds an entry (newest last), dropping the oldest once the day's list is over `max`.
function AuditLog.append(list: any, entry: Entry, max: number): { Entry }
	local out: { Entry } = {}
	if type(list) == "table" then
		for _, e in list do
			if type(e) == "table" and type(e.action) == "string" then
				table.insert(out, e)
			end
		end
	end
	table.insert(out, entry)
	while #out > max do
		table.remove(out, 1)
	end
	return out
end

function AuditLog.summary(e: Entry): string
	return string.format("[audit] %s (%d, %s) %s%s -> %s: %s", e.name, e.admin, e.role, e.action, if e.target then " on " .. e.target else "", if e.ok then "ok" else "DENIED", e.result)
end

return AuditLog
