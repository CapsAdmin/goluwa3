-- see the last line output in debug.txt for the last executed line before a crash
local f = io.open("debug.txt", "w")

debug.sethook(
	function(event)
		local info = debug.getinfo(2)
		f:write(string.format("%s:%d\n", info.short_src, info.currentline))
		f:flush()
	end,
	"l"
)
