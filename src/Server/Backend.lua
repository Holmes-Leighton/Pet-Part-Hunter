--!strict
-- Shared plumbing for everything the server writes to the outside: named DataStores with retries, and background HTTP
-- posts to your own backend. Used by the audit log, the metrics feed and alerts. (The trade log has its own, older
-- copy of the same ideas.) Nothing here ever blocks gameplay for long, and failures are reported, not thrown.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Backend = {}

local stores: { [string]: DataStore } = {}

function Backend.store(name: string): DataStore?
	local s = stores[name]
	if s == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(name)
		end)
		if ok then
			s = result
			stores[name] = result
		end
	end
	return s
end

-- Set by MetricsService so a DataStore failure shows up on the dashboard (spec section 9: "DataStore errors").
Backend.errorHook = nil :: ((string) -> ())?

-- Runs fn up to `tries` times with a growing pause. Returns whether it worked, and what it returned.
function Backend.retry(tries: number, fn: () -> any): (boolean, any)
	local lastErr: any = nil
	for attempt = 1, tries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < tries then
			task.wait(attempt)
		end
	end
	if Backend.errorHook then
		Backend.errorHook(tostring(lastErr))
	end
	return false, lastErr
end

-- Posts a JSON body to `url` in the background, with up to 5 tries and a growing wait. The API key comes from the Roblox
-- secret named in Config.Backend.SecretName, so it never appears in code. An empty url means "not set up": nothing is sent.
function Backend.post(url: string, body: any, label: string)
	if url == "" or (RunService:IsStudio() and not HttpService.HttpEnabled) then
		return
	end
	task.spawn(function()
		local json = HttpService:JSONEncode(body)
		for attempt = 1, 5 do
			local ok, result = pcall(function()
				local headers: { [string]: any } = { ["Content-Type"] = "application/json" }
				local secretOk, secret = pcall(function()
					return (HttpService :: any):GetSecret(Config.Backend.SecretName)
				end)
				if secretOk and secret then
					headers["Authorization"] = secret:AddPrefix("Bearer ")
				end
				return HttpService:RequestAsync({ Url = url, Method = "POST", Headers = headers, Body = json })
			end)
			if ok and result.Success then
				return
			end
			task.wait(2 ^ attempt)
		end
		warn("[PetPartHunter] " .. label .. " could not be delivered to the backend after 5 tries")
	end)
end

-- True when we can rely on DataStores: they exist, or we are in Studio where they are usually off.
function Backend.available(name: string): boolean
	return Backend.store(name) ~= nil or RunService:IsStudio()
end

return Backend
