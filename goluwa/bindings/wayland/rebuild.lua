local bindgen = require("bindings.wayland.bindgen")

do
	local f = io.open("goluwa/bindings/wayland/wayland.lua", "w")
	f:write(bindgen.generate("goluwa/bindings/wayland/wayland.xml"))
	f:close()
end

do
	local f = io.open("goluwa/bindings/wayland/xdg_shell.lua", "w")
	f:write(bindgen.generate("goluwa/bindings/wayland/xdg-shell.xml"))
	f:close()
end

do
	local f = io.open("goluwa/bindings/wayland/xdg_decoration.lua", "w")
	f:write(bindgen.generate("goluwa/bindings/wayland/xdg-decoration-unstable-v1.xml"))
	f:close()
end

do
	local f = io.open("goluwa/bindings/wayland/pointer_constraints.lua", "w")
	f:write(bindgen.generate("goluwa/bindings/wayland/pointer-constraints-unstable-v1.xml"))
	f:close()
end

do
	local f = io.open("goluwa/bindings/wayland/relative_pointer.lua", "w")
	f:write(bindgen.generate("goluwa/bindings/wayland/relative-pointer-unstable-v1.xml"))
	f:close()
end
