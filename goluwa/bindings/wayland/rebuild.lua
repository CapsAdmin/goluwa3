local bindgen = require("bindings.wayland.bindgen")

do
	local f = io.open("goluwa/bindings/wayland/wayland.lua", "w")
	f:write(bindgen.generate("goluwa/protocols/wayland.xml"))
	f:close()
end

do
	local f = io.open("goluwa/bindings/wayland/xdg_shell.lua", "w")
	f:write(bindgen.generate("goluwa/protocols/xdg-shell.xml"))
	f:close()
end
