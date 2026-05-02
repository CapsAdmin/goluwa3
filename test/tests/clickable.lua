local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Clickable = import("game/addons/gui/lua/ui/elements/clickable.lua")
local theme = import("game/addons/gui/lua/ui/theme.lua")

T.Test("clickable creates panel with correct name and initial state", function()
	-- Ensure theme is initialized
	if not theme.active then
		theme.Initialize()
	end

	local col = Clickable{
		Size = Vec2(200, 50),
		OnClick = function() end,
	}

	-- Verify name
	assert(col.Name == "clickable", "Expected name to be 'clickable', got: " .. tostring(col.Name))

	-- Verify initial state
	assert(col:GetState("hovered") == false, "Expected hovered to be false")
	assert(col:GetState("pressed") == false, "Expected pressed to be false")
	assert(col:GetState("disabled") == false, "Expected disabled to be false")
	assert(col:GetState("active") == false, "Expected active to be false")
	assert(col:GetState("mode") == "filled", "Expected mode to be 'filled', got: " .. tostring(col:GetState("mode")))
end)

T.Test("clickable state updates via SetState", function()
	local col = Clickable{
		Size = Vec2(200, 50),
		OnClick = function() end,
	}

	-- Simulate hover
	col:SetState("hovered", true)
	assert(col:GetState("hovered") == true, "Expected hovered to be true after setting")

	-- Simulate press
	col:SetState("pressed", true)
	assert(col:GetState("pressed") == true, "Expected pressed to be true after setting")

	-- Simulate disabled
	col:SetState("disabled", true)
	assert(col:GetState("disabled") == true, "Expected disabled to be true after setting")
end)

T.Test("clickable respects Disabled prop", function()
	local disabled_col = Clickable{
		Size = Vec2(200, 50),
		Disabled = true,
		OnClick = function() end,
	}
	assert(disabled_col:GetState("disabled") == true, "Expected disabled clickable to have disabled=true")
end)

T.Test("clickable respects Mode prop", function()
	local outline_col = Clickable{
		Size = Vec2(200, 50),
		Mode = "outline",
		OnClick = function() end,
	}
	assert(outline_col:GetState("mode") == "outline", "Expected mode to be 'outline', got: " .. tostring(outline_col:GetState("mode")))

	local text_col = Clickable{
		Size = Vec2(200, 50),
		Mode = "text",
		OnClick = function() end,
	}
	assert(text_col:GetState("mode") == "text", "Expected mode to be 'text', got: " .. tostring(text_col:GetState("mode")))
end)
