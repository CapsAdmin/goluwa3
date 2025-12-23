local prototype = require("prototype")
local timer = require("timer")
local sockets = library()
require("sockets.http")(sockets)
require("sockets.tcp_client")(sockets)
require("sockets.tcp_server")(sockets)
require("sockets.udp_client")(sockets)
require("sockets.udp_server")(sockets)
require("sockets.websocket_client")(sockets)
require("sockets.websocket_server")(sockets)
require("sockets.http11_client")(sockets)
require("sockets.http11_server")(sockets)
require("sockets.download")(sockets)
sockets.pool = prototype.CreateObjectPool("sockets")

timer.Repeat(
	"sockets",
	1 / 30,
	0,
	function()
		sockets.pool:call("Update")
	end,
	nil,
	function(...)
		logn(...)
		return true
	end
)

return sockets
