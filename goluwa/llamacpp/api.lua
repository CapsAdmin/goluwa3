local http = require("sockets.http")
local llamacpp = library()
local api = http.CreateAPI("http://127.0.0.1:8080/")
local codec = require("codec")

function llamacpp.GetProps(model)
	local url = model and ("props?model=" .. model) or "props"
	return api.GET(url):ErrorLevel(2):Get()
end

function llamacpp.GetModels()
	return list.map(api.GET("models"):ErrorLevel(2):Get().data, function(v)
		return v.id
	end)
end

local function sse_stream(req, on_chunk)
	local buffer = ""
	return req:Subscribe("chunks", function(chunk)
		buffer = buffer .. chunk

		while true do
			local line, rest = buffer:match("(.-)\n(.*)")

			if not line then break end

			buffer = rest

			if line:starts_with("data: ") then
				local data = line:sub(7):trim()

				if data == "[DONE]" then
					break
				else
					on_chunk(codec.Decode("json", data))
				end
			end
		end
	end)
end

local function decode_res(res)
	local tbl = {}

	for chunk in res:gmatch("[^\n]+") do
		local json = chunk:match("data: (.+)")

		if json then
			if json == "[DONE]" then break end

			table.insert(tbl, codec.Decode("json", json))
		end
	end

	return tbl
end

function llamacpp.Completion(body)
	assert(body.model)
	local on_data = body.on_data
	body.on_data = nil

	if on_data then body.stream = true end

	local req = api.POST(
		"completion",
		{
			headers = {
				["Content-Type"] = "application/json",
				["Accept"] = on_data and "text/event-stream" or nil,
			},
			body = body,
			timeout = on_data and 60 or nil,
		}
	):ErrorLevel(2)

	if on_data then
		local str = sse_stream(req, on_data):Get()
		return decode_res(str)
	end

	return req:Get()
end

function llamacpp.ChatCompletion(body)
	assert(body.model)
	local on_data = body.on_data
	body.on_data = nil

	if on_data then body.stream = true end

	local req = api.POST(
		"v1/chat/completions",
		{
			headers = {
				["Content-Type"] = "application/json",
				["Accept"] = on_data and "text/event-stream" or nil,
			},
			body = body,
			timeout = on_data and 60 or nil,
		}
	):ErrorLevel(2)

	if on_data then
		local str = sse_stream(req, on_data):Get()
		return decode_res(str)
	end

	return req:Get()
end

function llamacpp.Infill(body)
	assert(body.model)
	assert(
		body.input_prefix or body.input_suffix,
		"infill requires at least input_prefix or input_suffix"
	)
	local on_data = body.on_data
	body.on_data = nil

	if on_data then body.stream = true end

	local req = api.POST(
		"infill",
		{
			headers = {
				["Content-Type"] = "application/json",
				["Accept"] = on_data and "text/event-stream" or nil,
			},
			body = body,
			timeout = on_data and 60 or nil,
		}
	):ErrorLevel(2)

	if on_data then
		local str = sse_stream(req, on_data):Get()
		return decode_res(str)
	end

	return req:Get()
end

return llamacpp
