local event = require("event")
local window = require("window")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local window = require("window")
local render = require("render.render")
local gfx = require("render2d.gfx")
local Rect = require("structs.rect")
local gui = require("gui.gui")
local META = prototype.CreateTemplate("panel_base")
META.IsPanel = true
prototype.ParentingTemplate(META)

function META:Initialize() end

function META:CreatePanel(name)
	return gui.Create(name, self)
end

function META:OnReload()
	self:InvalidateMatrices()
	self:InvalidateLayout()
end

function META:OnRemove()
	self:UnParent()
end

function META:IsWorld()
	return self.Name == "Root"
end

require("gui.components.transform")(META)
require("gui.components.hover")(META)
require("gui.components.animations")(META)
require("gui.components.drawing")(META)
require("gui.components.mouse_input")(META)
require("gui.components.focus")(META)
require("gui.components.resize")(META)
require("gui.components.key_input")(META)
require("gui.components.layout")(META)
return META:Register()
