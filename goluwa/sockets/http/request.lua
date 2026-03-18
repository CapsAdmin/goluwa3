local http = import("goluwa/sockets/http.lua")
local timer = import("goluwa/timer.lua")
local event = import("goluwa/event.lua")
local multipart_boundary = "Goluwa" .. os.time()
local multipart = string.format("multipart/form-data;boundary=%q", multipart_boundary)

function http.Request(tbl, no_task)
	local HTTPClient = import("goluwa/sockets/http/http11_client.lua")

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
				tbl.callback{
					body = "",
					content = "",
					header = client.http.header,
					code = tonumber(client.http.code),
				}
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
			tbl.callback{
				body = client.http.body,
				content = client.http.body,
				header = client.http.header,
				code = tonumber(client.http.code),
			}
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

			if v.filename then body = body .. ";filename=\"" .. v.filename .. "\"" end

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
