local cocoa = require("cocoa")
local threads = require("threads")
local dump = require("helpers.table_print").print

-- Create and open window
local wnd = cocoa.window()
wnd:Initialize()
wnd:OpenWindow()

print("Event Test - Press keys, move mouse, click buttons")
print("Press ESC to exit")
print("")

-- Main event loop
while true do
	local events = wnd:ReadEvents()

	for _, event in ipairs(events) do
        local type = event.type
        print("event:", type)
        event.type = nil
        dump(event)
		if type == "window_close" then
			goto exit_loop
        end
	end

	threads.sleep(16) -- ~60 FPS
end

::exit_loop::