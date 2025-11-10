local audio = require("audio")
local threads = require("threads")

local length_ms = 1000

function audio.callback(buffer, num_samples, config)
	for i = 0, num_samples - 1, 2 do
		for j = 0, config.channels - 1 do
			buffer[i + j] = (math.random() * 2.0) - 1
			buffer[i + j] = (math.random() * 2.0) - 1
		end
	end
end

audio.start()
threads.sleep(length_ms)
audio.stop()
