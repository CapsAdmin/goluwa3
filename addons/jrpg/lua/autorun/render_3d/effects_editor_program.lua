local commands = import("goluwa/cli/commands.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local effects_editor = import("lua/jrpg/effects_editor.lua")
desktop.RegisterProgram{
	Name = "Effects editor",
	Icon = "layout",
	Positioned = true,
	Interactive = true,
	Create = effects_editor.Create,
	OnEscape = function(window)
		window:OnClose()
		return true
	end,
}

commands.Add("source_particle=string", function(text)
	local name, err = effects_editor.SelectSourceParticle(text)

	if not name then error(err, 0) end

	effects_editor.Create()
	llog("opened source particle %s", name)
end)

commands.Add("source_particles=string|nil", function(text)
	local names = effects_editor.ListSourceParticles(text)

	for _, name in ipairs(names) do
		logn(name)
	end

	llog("%d source particles%s", #names, text and (" matching " .. text) or "")
end)
