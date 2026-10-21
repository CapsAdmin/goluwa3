local system = import("goluwa/system.lua")
local sleep = import("goluwa/bindings/threads.lua").sleep
local bin_download = {}
bin_download.platform = (
		jit.os == "Windows" and
		"windows" or
		jit.os == "OSX" and
		"macos" or
		"linux"
	) .. "-" .. jit.arch:lower()

function bin_download.GetFileName(path)
	return path:match("([^/\\]+)$")
end

function bin_download.ReadBinary(path)
	local file = assert(io.open(path, "rb"))
	local data = file:read("*a")
	file:close()
	return data
end

function bin_download.WriteBinary(path, data)
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
end

function bin_download.GetTerminal()
	return import("goluwa/cli/repl.lua").GetTerminal()
end

function bin_download.ReadKey()
	local term = bin_download.GetTerminal()

	while true do
		local event = term:ReadEvent()

		if event and not event.mouse and event.key then
			if event.modifiers and event.modifiers.ctrl and event.key == "c" then
				error("aborted", 0)
			end

			return event.key
		end

		sleep(10)
	end
end

function bin_download.Fetch(url, label)
	local http = import("goluwa/sockets/http.lua")
	import("goluwa/sockets/http/download.lua")
	local socket_pool = import("goluwa/sockets/socket_pool.lua")
	local body, err
	local next_percent = 0
	http.DownloadSocket(
		url,
		function(data)
			body = data
		end,
		function(reason)
			err = reason
		end,
		function(chunk, written, total)
			if total ~= math.huge and total and written * 100 / total >= next_percent then
				logf("[download] %s: %d%%\n", label, next_percent)
				next_percent = next_percent + 10
			end
		end
	)
	local start = system.GetTime()

	while not body and not err do
		socket_pool.Update()
		sleep(5)

		if system.GetTime() - start > 600 then err = "timed out" end
	end

	if err then return nil, tostring(err) end

	return body
end

function bin_download.Download(release, asset, directory)
	if not asset.sha256 then
		return nil,
		"bin_manifest.lua has no sha256 for " .. asset.file .. ", run the build-binaries workflow and paste its hashes"
	end

	local url = release .. asset.file
	local data, err = bin_download.Fetch(url, asset.file)

	if not data then return nil, "could not fetch " .. url .. ": " .. err end

	local hash = import("goluwa/crypto.lua").SHA256(data)

	if hash ~= asset.sha256 then
		return nil, "sha256 mismatch for " .. asset.file .. ": expected " .. asset.sha256 .. " got " .. hash
	end

	local path = directory .. asset.file
	bin_download.WriteBinary(path, data)
	logf("[download] wrote %s\n", path)
	return path
end

return bin_download
