local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Texture = import("goluwa/render/texture.lua")
local react = import("goluwa/render2d/ui/react.lua")
local TextureViewer = import("lua/texture_viewer.lua")

local function find_all(root, type_name)
	local found = {}

	for _, child in ipairs(root:GetChildrenList()) do
		if child.Type == type_name then found[#found + 1] = child end
	end

	return found
end

local function find_text(root, text)
	for _, child in ipairs(find_all(root, "panel_text")) do
		if child.text:GetText() == text then return child end
	end
end

T.Test2D("texture viewer shows the texture info and reads the pixel under the mouse", function()
	local texture = Texture.New{width = 8, height = 4}
	local window = TextureViewer(texture, "textures/test.png")
	T(find_text(window, "textures/test.png") ~= nil)["=="](true)
	T(find_text(window, "8 × 4") ~= nil)["=="](true)
	local canvas
	local can_read = texture:CanDownload()

	for _, panel in ipairs(window:GetChildrenList()) do
		if panel:GetName() == "TextureCanvas" then canvas = panel end
	end

	T(canvas ~= nil)["=="](true)
	local idle = can_read and "-" or "unavailable for " .. texture.format
	T(find_text(window, idle) ~= nil)["=="](true)
	canvas.transform:SetSize(Vec2(400, 200))
	canvas.OnMouseMove(canvas, Vec2(200, 100))
	react.Flush()

	if can_read then T(find_text(window, idle) == nil)["=="](true) end

	canvas.OnMouseMove(canvas, Vec2(-50, -50))
	react.Flush()
	T(find_text(window, idle) ~= nil)["=="](true)
	window:Remove()
	react.Flush()
	texture:Remove()
end)

T.Test2D("texture viewer channel toggles and reset view go through state", function()
	local texture = Texture.New{width = 8, height = 8}
	local window = TextureViewer(texture, "textures/test.png")
	local boxes = {}

	for _, box in ipairs(find_all(window, "panel_checkbox")) do
		boxes[box.Text] = box
	end

	T(boxes.R.Value)["=="](true)
	boxes.G.OnChange(false, boxes.G)
	boxes.B.OnChange(false, boxes.B)
	react.Flush()
	T(boxes.G.Value)["=="](false)
	T(boxes.B.Value)["=="](false)
	T(boxes.R.Value)["=="](true)
	local reset

	for _, button in ipairs(find_all(window, "panel_button")) do
		if button:GetText() == "Reset View" then reset = button end
	end

	reset:CallLocalEvent("OnClick")
	react.Flush()
	T(boxes.G.Value)["=="](true)
	T(boxes.B.Value)["=="](true)
	window:Remove()
	react.Flush()
	texture:Remove()
end)
