local callback = require("callback")
local event = require("event")
local tasks = require("tasks")
local codec = require("codec")
local timer = require("timer")
local http = library()
package.loaded["http"] = http
package.loaded["sockets.http"] = http

http.MimeToExtension = {
	["audio/aac"] = "aac",
	["application/x-abiword"] = "abw",
	["application/x-freearc"] = "arc",
	["video/x-msvideo"] = "avi",
	["application/vnd.amazon.ebook"] = "azw",
	["application/octet-stream"] = "bin",
	["image/bmp"] = "bmp",
	["application/x-bzip"] = "bz",
	["application/x-bzip2"] = "bz2",
	["application/x-csh"] = "csh",
	["text/css"] = "css",
	["text/csv"] = "csv",
	["application/msword"] = "doc",
	["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
	["application/vnd.ms-fontobject"] = "eot",
	["application/epub+zip"] = "epub",
	["image/gif"] = "gif",
	["text/html"] = "html",
	["image/vnd.microsoft.icon"] = "ico",
	["text/calendar"] = "ics",
	["application/java-archive"] = "jar",
	["image/jpeg"] = "jpg",
	["text/javascript"] = "js",
	["application/json"] = "json",
	["audio/midi audio/x-midi"] = "mid",
	["application/javascript"] = "mjs",
	["audio/mpeg"] = "mp3",
	["video/mpeg"] = "mpeg",
	["application/vnd.apple.installer+xml"] = "mpkg",
	["application/vnd.oasis.opendocument.presentation"] = "odp",
	["application/vnd.oasis.opendocument.spreadsheet"] = "ods",
	["application/vnd.oasis.opendocument.text"] = "odt",
	["audio/ogg"] = "oga",
	["video/ogg"] = "ogv",
	["application/ogg"] = "ogx",
	["font/otf"] = "otf",
	["image/png"] = "png",
	["application/pdf"] = "pdf",
	["application/vnd.ms-powerpoint"] = "ppt",
	["application/vnd.openxmlformats-officedocument.presentationml.presentation"] = "pptx",
	["application/x-rar-compressed"] = "rar",
	["application/rtf"] = "rtf",
	["application/x-sh"] = "sh",
	["image/svg+xml"] = "svg",
	["application/x-shockwave-flash"] = "swf",
	["application/x-tar"] = "tar",
	["image/tiff"] = "tif",
	["font/ttf"] = "ttf",
	["text/plain"] = "txt",
	["application/vnd.visio"] = "vsd",
	["audio/wav"] = "wav",
	["audio/webm"] = "weba",
	["video/webm"] = "webm",
	["image/webp"] = "webp",
	["font/woff"] = "woff",
	["font/woff2"] = "woff2",
	["application/xhtml+xml"] = "xhtml",
	["application/vnd.ms-excel"] = "xls",
	["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = "xlsx",
	["application/xml if not readable from casual users (RFC 3023, section 3)"] = "xml",
	["application/zip"] = "zip",
	["video/3gpp"] = "3gp",
	["video/3gpp2"] = "3g2",
	["application/x-7z-compressed"] = "7z",
	["application/vnd.microsoft.portable-executable"] = "exe",
}

function http.MixinHTTP(META)
	function META:InitializeHTTPParser()
		self.http = {
			raw_header = "",
			raw_body = "",
			stage = "header",
		}
	end

	do
		local function decode_chunk(str)
			local hex_num, rest = str:match("^([abcdefABCDEF0123456789]-)\r\n(.+)")

			if hex_num then
				local num = tonumber("0x" .. hex_num)
				return rest:sub(1, num),
				rest:sub(num + 3),
				rest:sub(num + 3):starts_with("0\r\n\r\n")
			end
		end

		function META:WriteHTTP(chunk, is_response)
			local state = self.http

			if state.stage == "header" then
				if not is_response then
					if #state.raw_header > 4 and not state.raw_header:starts_with("HTTP") then
						return self:Error(
							"header does not start with HTTP (first 10 bytes: " .. state.raw_header:sub(10) .. ")"
						)
					end
				end

				state.raw_header = state.raw_header .. chunk
				local start, stop = state.raw_header:find("\r\n\r\n", 1, true)

				if start then
					local header = state.raw_header:sub(1, stop)
					chunk = state.raw_header:sub(stop + 1) -- resume body here
					state.raw_header = header

					do
						local keyvalues = {}

						for i, line in ipairs(header:split("\r\n")) do
							if i == 1 then
								local ok

								if is_response then
									state.method, state.path, state.version = line:match("^(%u+) (%S+) (HTTP/%d+%.%d+)$")

									if self:OnHTTPEvent("response") == false then
										self:InitializeHTTPParser()
										return
									end
								else
									state.version, state.code, state.status = line:match("^(HTTP/%d+%.%d+) (%d+) (.+)$")

									if self:OnHTTPEvent("status") == false then
										self:InitializeHTTPParser()
										return
									end
								end

								if state.version ~= "HTTP/1.1" and state.version ~= "HTTP/1.0" then
									return self:Error(tostring(state.version) .. " protocol not supported")
								end
							else
								local keyval = line:split(": ")
								local key, val = keyval[1], keyval[2]
								keyvalues[key:lower()] = val
							end
						end

						-- normalize some values
						do
							local content_length = tonumber(keyvalues["content-length"])

							if content_length == 0 then content_length = nil end

							keyvalues["content-length"] = content_length
						end

						keyvalues["connection"] = keyvalues["connection"] and keyvalues["connection"]:lower() or nil
						keyvalues["content-encoding"] = keyvalues["content-encoding"] or "identity"
						state.header = keyvalues
					end

					if self:OnHTTPEvent("header") == false then
						self:InitializeHTTPParser()
						return
					end

					state.stage = "body"
				end
			end

			if state.stage == "body" then
				if state.header["transfer-encoding"] == "chunked" then
					state.remaining_chunk = state.remaining_chunk or ""
					local decoded = ""
					local remaining = state.remaining_chunk .. chunk

					while true do
						local decoded_chunk, rest, done = decode_chunk(remaining)

						if done then
							state.chunked_done = true
							decoded = decoded .. decoded_chunk

							break
						end

						if not decoded_chunk or rest == "" then break end

						decoded = decoded .. decoded_chunk
						remaining = rest
					end

					state.remaining_chunk = remaining
					self:WriteBody(decoded)
					state.current_body_chunk = decoded
				else
					self:WriteBody(chunk)
					state.current_body_chunk = chunk
				end

				if state.current_body_chunk and state.current_body_chunk ~= "" then
					if self:OnHTTPEvent("chunk") == false then return end
				end

				local body = nil

				if state.header["transfer-encoding"] == "chunked" then
					if state.chunked_done then body = self:GetWrittenBodyString() end
				elseif
					state.header["content-length"] and
					self:GetWrittenBodySize() >= state.header["content-length"]
				then
					body = self:GetWrittenBodyString()
				end

				if body then
					local encoding = state.header["content-encoding"]

					if encoding ~= "identity" then
						if encoding == "gzip" then
							local ok, str = pcall(codec.Decode, "gunzip", body)

							if ok == false then
								return self:Error("failed to parse " .. encoding .. " body: " .. str)
							end

							body = str
						else
							return self:Error("unknown content-encoding: " .. encoding)
						end
					end

					state.body = body
					self:OnHTTPEvent("body")
				end
			end

			return true
		end
	end

	function META:WriteBody(data)
		self.http.raw_body = self.http.raw_body .. data
	end

	function META:GetWrittenBodySize()
		return #self.http.raw_body
	end

	function META:GetWrittenBodyString()
		return self.http.raw_body
	end

	function META:OnHTTPEvent(what) end
--function META:Error(what) return false end
end





local function default_header(header, key, val)
	if header[key] == nil then
		header[key] = val
	elseif header[key] == false then
		header[key] = nil
	end
end

local function build_http(tbl)
	local str = ""

	if tbl.method then str = str .. tbl.method .. " " end

	if tbl.path then str = str .. tbl.path .. " " end

	str = str .. tbl.protocol

	if tbl.code then str = str .. " " .. tbl.code end

	if tbl.status then str = str .. " " .. tbl.status end

	str = str .. "\r\n"

	if tbl.header then
		for k, v in pairs(tbl.header) do
			str = str .. k .. ": " .. tostring(v) .. "\r\n"
		end
	end

	str = str .. "\r\n"

	if tbl.body then str = str .. tbl.body end

	return str
end

function http.HTTPRequest(method, uri, header, body)
	header = header or {}
	default_header(header, "User-Agent", "goluwa/" .. jit.os)
	default_header(header, "Accept", "*/*")
	default_header(header, "Accept-Encoding", "identity")

	do
		local host = uri.host

		if uri.port then host = host .. ":" .. uri.port end

		default_header(header, "Host", host)
	end

	default_header(header, "Connection", "keep-alive")
	default_header(header, "DNT", "1")

	if body then
		default_header(header, "Content-Length", #body)
		default_header(header, "Content-Type", "application/octet-stream")
	end

	local str = build_http(
		{
			protocol = "HTTP/1.1",
			method = method,
			path = uri.path,
			header = header,
			body = body,
		}
	)
	return str
end

function http.HTTPResponse(code, status, header, body)
	header = header or {}

	if body then default_header(header, "Content-Length", #body) end

	local str = build_http(
		{
			protocol = "HTTP/1.1",
			code = code,
			status = status,
			header = header,
			body = body,
		}
	)
	return str
end

do
	local multipart_boundary = "Goluwa" .. os.time()
	local multipart = string.format("multipart/form-data;boundary=%q", multipart_boundary)

	function http.Request(tbl, no_task)

		local HTTPClient = require("sockets.http.http11_client")

		if not no_task then
			local a, b, c = event.Call("SocketRequest", tbl)

			if a ~= nil then return a, b, c end
		end

		local client = HTTPClient.New()
		client.socket:set_option("keepalive", true)
		client.NoCodeError = true
		client.OnReceiveStatus = function(_, code, status)
			if tbl.code_callback then
				local ret = tbl.code_callback(tonumber(code), status)

				if ret == false then client:Close() end

				return ret
			end
		end
		client.OnReceiveHeader = function(_, header)
			local ret

			if tbl.header_callback then
				ret = tbl.header_callback(header)

				if ret == false then client:Close() end
			end

			if tbl.method == "HEAD" then
				if tbl.callback then
					tbl.callback(
						{
							body = "",
							content = "",
							header = client.http.header,
							code = tonumber(client.http.code),
						}
					)
				end

				client:Close()
				return false
			end

			return ret
		end
		client.OnReceiveBodyChunk = function(_, chunk)
			if tbl.on_chunks then
				tbl.on_chunks(chunk, client:GetWrittenBodySize(), client.http and client.http.header)
			end
		end
		client.OnReceiveBody = function(_, body)
			if tbl.callback then
				tbl.callback(
					{
						body = client.http.body,
						content = client.http.body,
						header = client.http.header,
						code = tonumber(client.http.code),
					}
				)
			end
		end
		client.OnError = function(_, err, tr)
			if client.timedout then return end

			client.errored = true

			if tbl.error_callback then
				tbl.error_callback(err)
			else
				llog("http.Request: " .. err)
				logn(tr)
			end
		end

		if tbl.timeout then
			timer.Delay(tbl.timeout, function()
				if client:IsValid() and not client.errored then
					client.timedout = true

					if tbl.timedout_callback then
						tbl.timedout_callback()
					elseif tbl.error_callback then
						tbl.error_callback("timeout")
					else
						llog("http.Request: timeout (" .. tbl.url .. ")")
					end

					client:Remove()
				end
			end)
		end

		if tbl.files then
			local body = ""

			for i, v in ipairs(tbl.files) do
				body = body .. "\r\n--" .. multipart_boundary
				body = body .. "\r\nContent-Disposition: form-data; name=\"" .. v.name .. "\""

				if v.filename then
					body = body .. ";filename=\"" .. v.filename .. "\""
				end

				body = body .. "\r\nContent-Type:" .. (v.type or "application/octet-stream")
				body = body .. "\r\n\r\n" .. v.data
			end

			body = body .. "\r\n--" .. multipart_boundary .. "--"
			tbl.post_data = body
			tbl.header = tbl.header or {}
			tbl.header["Content-Type"] = multipart
		end

		local ok, err = pcall(function()
			client:Request(tbl.method or "GET", tbl.url, tbl.header, tbl.post_data)
		end)

		if not ok then client:Error(err) end

		return client
	end

	function http.Get(url, callback, timeout, binary, debug)
		return http.Request({
			method = "GET",
			url = url,
			callback = callback,
		})
	end

	function http.Post(url, body, callback)
		http.Request({
			method = "POST",
			url = url,
			callback = callback,
			body = body,
		})
	end
end

do
	local function make_request(self, url, data, method)
		local reject = self.callbacks.reject
		local resolve = self.callbacks.resolve
		local post_data

		if data then
			if
				data.headers and
				table.lowecase_lookup(data.headers, "content-type") and
				table.lowecase_lookup(data.headers, "content-type"):starts_with("application/json")
			then
				post_data = codec.Encode("json", data.body)
			else
				post_data = data.body
			end
		end

		local socket
		socket = http.Request(
			{
				url = url,
				method = method,
				header_callback = function(...)
					self.callbacks.header(...)

					if data and data.header_callback then data.header_callback(...) end
				end,
				on_chunks = function(...)
					self.callbacks.chunks(...)

					if data and data.on_chunks then data.on_chunks(...) end
				end,
				callback = function(data_res)
					if
						data_res.header and
						table.lowecase_lookup(data_res.header, "content-type") and
						table.lowecase_lookup(data_res.header, "content-type"):starts_with("application/json")
					then
						resolve(codec.Decode("json", data_res.body))
					else
						resolve(data_res.body)
					end
				end,
				code_callback = function(code, status)
					if not tostring(code):starts_with("2") and not tostring(code):starts_with("3") then
						socket:Remove()
						reject(status .. "(" .. code .. ") url:" .. url)
						return false
					end

					if data and data.code_callback then return data.code_callback(code, status) end
				end,
				error_callback = function(err)
					if socket then socket:Remove() end

					reject(err)

					if data and data.error_callback then data.error_callback(err) end
				end,
				header = data and data.headers,
				post_data = post_data,
				files = data and data.files,
				timeout = data and data.timeout,
				timedout_callback = data and data.timedout_callback,
			},
			true
		)
		self.on_stop = function()
			if socket:IsValid() then socket:Remove() end
		end
	end

	local start = callback.WrapKeyedTask(make_request)
	local methods = {
		"GET",
		"HEAD",
		"POST",
		"PUT",
		"DELETE",
		"CONNECT",
		"OPTIONS",
		"TRACE",
		"PATCH",
	}

	for _, method in ipairs(methods) do
		http[method] = function(url, data)
			local cb = start(url, data, method)
			cb.warn_unhandled = false
			return cb
		end
	end

	function http.CreateAPI(base_url, default_headers)
		local api = {}

		for _, method in ipairs(methods) do
			api[method] = function(url, data)
				data = data or {}
				data.headers = data.headers or {}

				if default_headers then
					local default_headers = default_headers

					if type(default_headers) == "function" then
						default_headers = default_headers(data)
					end

					for k, v in pairs(default_headers) do
						data.headers[k] = data.headers[k] or v
					end
				end

				local cb = callback.Create()
				make_request(cb, base_url .. url, data, method)
				cb:Start()
				cb.warn_unhandled = false
				return cb
			end
		end

		return api
	end
end

function http.async(func)
	return tasks.CreateTask(func)
end

function http.query(url, tbl)
	return url .. http.EncodeQuery(tbl)
end

do
	event.AddListener("SocketRequest", "socket_tasks", function(info)
		if not info.callback and tasks.GetActiveTask() then
			local data
			local err
			info.callback = function(val)
				data = val
			end
			info.error_callback = function(val)
				err = val
			end
			info.timedout_callback = function(val)
				err = val
			end
			http.Request(info)

			while not data and not err do
				tasks.Wait()
			end

			return data, err
		end
	end)
end


require("sockets.http.uri")
require("sockets.http.download")

return http