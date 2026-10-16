--!strict
-- Tiny test harness: Test.case(name, fn), Test.eq / Test.truthy / Test.near, Test.done() sets the exit status.

local Test = {}

local passed = 0
local failed = 0
local failures: { string } = {}

local function show(v: any): string
	if type(v) == "table" then
		local parts = {}
		for k, x in pairs(v) do
			table.insert(parts, tostring(k) .. "=" .. show(x))
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return tostring(v)
end

function Test.case(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok    " .. name)
	else
		failed += 1
		table.insert(failures, name)
		print("  FAIL  " .. name .. "\n        " .. tostring(err))
	end
end

function Test.eq(actual: any, expected: any, label: string?)
	if show(actual) ~= show(expected) then
		error(string.format("%sexpected %s, got %s", label and (label .. ": ") or "", show(expected), show(actual)), 2)
	end
end

function Test.truthy(v: any, label: string?)
	if not v then
		error((label or "expected a truthy value") .. " (got " .. tostring(v) .. ")", 2)
	end
end

function Test.near(actual: number, expected: number, tol: number?, label: string?)
	local t = tol or 1e-6
	if math.abs(actual - expected) > t then
		error(string.format("%sexpected %s +/- %s, got %s", label and (label .. ": ") or "", tostring(expected), tostring(t), tostring(actual)), 2)
	end
end

function Test.done()
	print(string.format("  %d passed, %d failed", passed, failed))
	if failed > 0 then
		error("FAIL: " .. table.concat(failures, "; "), 0)
	end
end

return Test
