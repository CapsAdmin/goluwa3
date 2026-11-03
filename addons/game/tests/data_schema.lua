local T = import("test/environment.lua")
local data_schema = import("lua/data_schema.lua")
local data_items = import("lua/data_items.lua")

T.Test("a reference field that allows paths accepts an existing file besides the listed names", function()
	local schema = {
		Refs = {sprite = {"glow"}},
		Fields = {Sprite = {Ref = "sprite", Paths = true}, Plain = {Ref = "sprite"}},
	}
	T(#data_schema.Check(schema, {Sprite = "glow"}))["=="](0)
	T(#data_schema.Check(schema, {Sprite = "lua/emitters/hit_force.lua"}))["=="](0)
	T(#data_schema.Check(schema, {Sprite = "nothing/here.vtf"}))["=="](1)
	T(#data_schema.Check(schema, {Plain = "lua/emitters/hit_force.lua"}))["=="](1)
	local items = data_items.Build(
		{Sprite = "lua/emitters/hit_force.lua", Plain = "lua/emitters/hit_force.lua"},
		{Schema = schema, Name = "x", Changed = function() end, Restructured = function() end}
	)
	local by_text = {}

	for _, item in ipairs(items[1].Children) do
		by_text[item.Text] = item
	end

	T(by_text.Sprite.Options[1].Text)["=="]("lua/emitters/hit_force.lua")
	T(by_text.Plain.Options[1].Text)["=="]("lua/emitters/hit_force.lua (missing)")
end)
