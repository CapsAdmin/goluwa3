local prototype = require("prototype")
local timer = require("timer")
local pool = prototype.CreateObjectPool("sockets")

timer.Repeat(
	"sockets",
	1 / 30,
	0,
	function()
		pool:call("Update")
	end,
	nil,
	function(...)
		logn(...)
		return true
	end
)

return pool