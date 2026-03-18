local http = import("goluwa/sockets/http.lua")
local HTTPClient = import("goluwa/sockets/http/http11_client.lua")
local callback = import("goluwa/callback.lua")
local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")

local function posixtime2http(posix_time)
	return import("goluwa/date.lua")(posix_time):fmt("${http}")
end

local function http2posixtime(http_time)
	return (
		import("goluwa/date.lua")(http_time) - import("goluwa/date.lua").epoch()
	):spanseconds()
end

local function decode_data_uri(uri)
	local mime, encoding, data = uri:match("data:(.-);(.-),(.+)")

	if encoding == "" then encoding = "base64" end

	if encoding == "base64" then
		vfs.Write("test." .. http.MimeToExtension[mime], crypto.Base64Decode(data))
	else
		error("unknown encoding " .. encoding)
	end

	return
end

local function find_best_name(client)
	local contestants = {}

	if client.http.header["content-disposition"] then
		local file_name = client.http.header["content-disposition"]:match("filename=(%b\"\")")

		if file_name then
			file_name = file_name:sub(2, -2)
			list.insert(contestants, {score = math.huge, name = file_name})
		end
	end

	for _, url in ipairs(client:GetRedirectHistory()) do
		local score = 0
		local name = vfs.GetFileNameFromPath(url):gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)
		name = name:gsub("^(.+)%?.+$", "%1")
		local ext = vfs.GetExtensionFromPath(name)

		if #ext > 0 then score = score + 10 end

		score = score - (select(2, name:gsub("%p", "")) or 0)
		list.insert(contestants, {score = score, name = name})
	end

	list.sort(contestants, function(a, b)
		return a.score > b.score
	end)

	local name = contestants[1].name

	if client.http.header["content-type"] and #vfs.GetExtensionFromPath(name) == 0 then
		local mime = client.http.header["content-type"]:match("^(.-);") or
			client.http.header["content-type"]
		name = name .. "." .. http.MimeToExtension[mime] or "dat"
	end

	return name
end

local function move_and_finish(path, on_finish)
	assert(vfs.Rename(path .. ".part", vfs.GetFileNameFromPath(path)))
	on_finish(path)
end

http.active_downloads = http.active_downloads or {}

function http.DownloadSocket(url, on_finish, on_error, on_chunks, on_header, on_code)
	local client = HTTPClient.New()
	local lookup = {url = url, client = client}
	list.insert(http.active_downloads, lookup)
	local buffer = {}
	local written_size = 0
	local total_size = math.huge
	local done = false

	local function cleanup()
		if done then return false end

		done = true
		list.remove_value(http.active_downloads, lookup)
		return true
	end

	local function fail(reason)
		if not cleanup() then return end

		if on_error then
			on_error(reason)
		else
			llog("http.DownloadSocket(" .. url .. ") failed: " .. tostring(reason))
		end

		client:Close()
	end

	function client:OnReceiveStatus(status, reason)
		if status:starts_with("4") or status:starts_with("5") then
			local message = (reason or "HTTP error") .. "(" .. status .. ") url:" .. url
			fail(message)
			return false
		elseif on_code then
			on_code(tonumber(status))
		end
	end

	function client:WriteBody(chunk)
		list.insert(buffer, chunk)
		written_size = written_size + #chunk

		if on_chunks then
			on_chunks(chunk, written_size, total_size, client.friendly_name)
		end
	end

	function client:GetWrittenBodySize()
		return written_size
	end

	function client:GetWrittenBodyString()
		return list.concat(buffer)
	end

	function client:OnReceiveHeader(header, raw)
		client.friendly_name = find_best_name(self)
		total_size = header["content-length"] or total_size

		if on_header then on_header(header, raw) end
	end

	function client:OnReceiveBody(body)
		if not cleanup() then return end

		on_finish(body)
	end

	function client:OnError(reason)
		fail(reason)
	end

	function client:OnClose(reason)
		if not done then fail(reason or "closed") end
	end

	client:Request("GET", url)
	return client
end

http.DownloadRaw = http.DownloadSocket

function http.DownloadToPath(url, path, on_finish, on_error, on_progress, on_header)
	on_finish = on_finish or function(path)
		print("finished downloading " .. path)
	end
	on_error = on_error or function(reason)
		print("error ", reason)
	end
	on_progress = on_progress or
		function(bytes, size)
			if size == math.huge then size = "unknown" end

			print("progress: " .. bytes .. "/" .. size)
		end
	on_header = on_header or function(header) end
	local etag = vfs.GetAttribute(path .. ".part", "socket_download_etag") or
		vfs.GetAttribute(path, "socket_download_etag")
	local total_size = vfs.GetAttribute(path .. ".part", "socket_download_total_size") or
		vfs.GetSize(path) or
		0
	local file
	local written_size = 0
	local current_size = vfs.GetSize(path .. ".part") or 0
	local progress_size = math.huge

	if current_size > total_size then
		etag = nil
		current_size = 0
		vfs.Delete(path .. ".part")
	elseif current_size == total_size and total_size > 0 then
		move_and_finish(path, on_finish)
		return
	end

	local header = {}

	if etag and not total_size then header["If-None-Match"] = etag end

	if current_size > 0 then header["range"] = "bytes=" .. current_size .. "-" end

	local client = HTTPClient.New()
	client.url = url
	local lookup = {url = url, client = client}
	list.insert(http.active_downloads, lookup)
	event.Call("DownloadStart", client, url)
	client:Request("GET", url, header)

	function client:OnReceiveStatus(status, reason)
		if status:starts_with("4") then
			event.Call("DownloadStop", self, url, nil, "recevied code " .. status)
			return false
		else
			event.Call("DownloadCodeReceived", self, url, tonumber(status))
		end
	end

	function client:WriteBody(chunk)
		event.Call("DownloadChunkReceived", self, url, chunk)
		file:Write(chunk)
		written_size = written_size + #chunk
		on_progress(tonumber(file:GetPosition()), tonumber(total_size), client.friendly_name)
	end

	function client:GetWrittenBodySize()
		return written_size
	end

	function client:GetWrittenBodyString()
		file:PushPosition(0)
		local data = file:ReadAll()
		file:PopPosition()
		return data or ""
	end

	function client:OnReceiveHeader(header)
		client.friendly_name = find_best_name(self)

		if vfs.IsFile(path) and etag == header.etag then
			on_finish(path)
			self:Close()
			return false
		else
			file = vfs.Open(path .. ".part", "read_write")
			current_size = file:GetSize()
			file:SetPosition(current_size)

			if current_size == 0 then
				vfs.SetAttribute(path .. ".part", "socket_download_total_size", header["content-length"])
				total_size = header["content-length"]
			end
		end

		if header.etag then
			vfs.SetAttribute(path .. ".part", "socket_download_etag", header.etag)
			vfs.SetAttribute(path, "socket_download_etag", header.etag)
		end

		on_header(header)
		event.Call("DownloadHeaderReceived", self, url, header)
	end

	function client:OnReceiveBody(body)
		file:Flush()
		file:Close()
		move_and_finish(path, on_finish)
		list.remove_value(http.active_downloads, lookup)
		event.Call("DownloadStop", self, url, body)
	end

	function client:OnError(reason)
		on_error(reason)
		self:Close()
		list.remove_value(http.active_downloads, lookup)
	end

	return client
end

function http.StopDownload(url)
	for i = #http.active_downloads, 1, -1 do
		local v = http.active_downloads[i]

		if v.url == url then
			v.client:Close()
			list.remove(http.active_downloads, i)
		end
	end
end

do
	local start = callback.WrapKeyedTask(function(self, key, urls)
		local resolve = self.callbacks.resolve
		local reject = self.callbacks.reject
		local cbs = {}
		local fails = {}

		local function fail(url, reason)
			list.insert(fails, "failed to download " .. url .. ": " .. reason .. "\n")

			if #fails == #urls then
				local reason = ""

				for _, str in ipairs(fails) do
					reason = reason .. str
				end

				reject(reason)
			end
		end

		for i, url in ipairs(urls) do
			cbs[i] = http.Download(url):Then(function(...)
				resolve(url, ...)
			end):Catch(function(reason)
				fail(url, reason or "no reason")
			end):Subscribe("header", function(header)
				if
					(
						not header["content-length"] or
						header["content-length"] == 0
					)
					and
					not header["content-type"]
				then
					return false, "download length is 0"
				end

				for _, cb in ipairs(cbs) do
					if cb ~= cbs[i] then cb:Stop() end
				end
			end)
		end

		return true
	end)

	function http.DownloadFirstFound(urls)
		return start(list.concat(urls), urls)
	end
end

do
	local start = callback.WrapKeyedTask(function(self, url)
		local socket = http.DownloadSocket(
			url,
			self.callbacks.resolve,
			self.callbacks.reject,
			self.callbacks.chunks,
			self.callbacks.header
		)
		self.on_stop = function()
			if socket:IsValid() then socket:Remove() end
		end
		self.socket = socket
	end, 20, function(what, cb, key, queue)
		if what == "push" then
			llog("queueing %s (too many active downloads %s)", key, #queue)
		end
	end)

	function http.Download(url)
		return start(url)
	end
end
