local http = require("http")
local llamacpp = library()
local api = http.CreateAPI("http://127.0.0.1:8080/")
llamacpp.model = "Qwen3.5-35B-A3B-UD-Q4_K_XL_2"

function llamacpp.GetProps()
	return api.GET("props", {error_level = 4}):Get()
end

function llamacpp.GetModels()
	return api.GET("models", {error_level = 4}):Get()
end

function llamacpp.Completion(body)
	body.model = body.model or llamacpp.model
	return api.POST(
		"completion",
		{
			headers = {
				["Content-Type"] = "application/json",
			},
			body = body,
			error_level = 4,
		}
	)
end

function llamacpp.ChatCompletionStream(messages, on_delta)
	local buffer = ""
	return api.POST(
		"v1/chat/completions",
		{
			headers = {
				["Content-Type"] = "application/json",
				["Accept"] = "text/event-stream",
			},
			body = {
				model = llamacpp.model,
				messages = messages,
				stream = true,
			},
			error_level = 4,
			timeout = 60,
		}
	):Subscribe("chunks", function(chunk)
		buffer = buffer .. chunk

		while true do
			local line, rest = buffer:match("(.-)\n(.*)")

			if not line then break end

			buffer = rest

			if line:starts_with("data: ") then
				local data = line:sub(7):trim()

				if data ~= "[DONE]" then
					local ok, decoded = pcall(function()
						return require("codec").Decode("json", data)
					end)

					if ok and decoded and decoded.choices and decoded.choices[1].delta then
						local delta = decoded.choices[1].delta
						local text = delta.content or delta.reasoning_content

						if text then on_delta(tostring(text)) end
					end
				end
			end
		end
	end)
end

http.async(function()
	local props = llamacpp.GetProps()
	local models = llamacpp.GetModels()

	-- Non-streaming example
	if false then
		local result = llamacpp.Completion(
			{
				model = "Qwen3.5-35B-A3B-UD-Q4_K_XL_2",
				prompt = "The meaning of life is",
				n_predict = 32,
			}
		):Get()
		print("Full Result:", result.content)
	end

	print("\nStreaming response:")
	llamacpp.ChatCompletionStream({
		{role = "system", content = "You are a helpful assistant."},
		{role = "user", content = "Write a haiku about Lua."},
	}, function(delta)
		io.write(delta)
		io.flush()
	end):Get()
	print("\nStream finished.")
end)