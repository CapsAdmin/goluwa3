local thread_pool = import("goluwa/thread_pool.lua")
local system = import("goluwa/system.lua")
-- host names resolved on the thread pool: getaddrinfo blocks for as long as the resolver takes (seconds when it is
-- slow), so it never runs on the main thread; answers are kept for TTL seconds
local dns = {}
dns.TTL = 300
local cache = {}
local waiting = {}
local JOB = [[
	local input = ...
	local socket = import("goluwa/bindings/socket.lua")
	local info, err = socket.find_first_address_info(input.host, input.service, nil, "inet", "stream", "tcp")

	if not info then return {err = tostring(err)} end

	return {address = info:get_ip()}
]]

-- calls callback(address) with the host's numeric address, or callback(nil, err): at once for a numeric host or one
-- resolved lately, else once a worker has resolved it (one lookup however many ask for the same host meanwhile)
function dns.Resolve(host, service, callback)
	if host:find("^%d+%.%d+%.%d+%.%d+$") then return callback(host) end

	local entry = cache[host]

	if entry and entry.expires > system.GetElapsedTime() then
		return callback(entry.address)
	end

	if waiting[host] then
		list.insert(waiting[host], callback)
		return
	end

	waiting[host] = {callback}

	thread_pool.Run(JOB, {host = host, service = tostring(service)}, math.huge):OnDone(function(job)
		local callbacks = waiting[host]
		waiting[host] = nil
		local address = job.meta and job.meta.address
		local err = job.err or job.meta and job.meta.err

		if address then
			cache[host] = {address = address, expires = system.GetElapsedTime() + dns.TTL}
		end

		for _, cb in ipairs(callbacks) do
			cb(address, err)
		end
	end)
end

return dns
