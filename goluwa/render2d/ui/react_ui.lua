local vfs = import("goluwa/vfs.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local DIRECTORIES = {"elements", "widgets"}
local ALIASES = {MenuItem = "goluwa/render2d/ui/elements/context_menu_item.lua"}
local ui = {Panel = react.Element(Panel)}
setmetatable(
	ui,
	{
		__index = function(self, name)
			local path = ALIASES[name]

			if not path then
				local file = name:gsub("(%l)(%u)", "%1_%2"):lower() .. ".lua"

				for _, directory in ipairs(DIRECTORIES) do
					local candidate = "goluwa/render2d/ui/" .. directory .. "/" .. file

					if vfs.IsFile(candidate) then
						path = candidate

						break
					end
				end
			end

			assert(path, "there is no ui element named " .. name)
			local element = react.Element(import(path))
			rawset(self, name, element)
			return element
		end,
	}
)
return ui
