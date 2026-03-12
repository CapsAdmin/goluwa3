local http = import("goluwa/sockets/http.lua")
local callback = import("goluwa/callback.lua")
local codec = import("goluwa/codec.lua")

function http.CreateAPI(base_url, default_headers)
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
	local start = callback.WrapKeyedTask(make_request)
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