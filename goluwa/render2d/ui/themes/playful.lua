-- Playful theme: a late-90s mish mash of DK-BALL arcade splash screens,
-- DOSBox/Win95 config dialogs, and demoscene. Small repeating pattern
-- textures, hard 2px bevels, chrome gradient text, hot saturated palette.
-- Square corners, hard offset shadows, no blur, no rounded corners.
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local Texture = import("goluwa/render/texture.lua")
local BaseTheme = import("./base.lua")
local PlayfulTheme = objects.CreateTemplate("ui_theme_playful")
PlayfulTheme.Base = BaseTheme
PlayfulTheme.Name = "playful"
local LIGHT_RAISED = math.rad(45)
local FONT_HEADING = "Titan One"
local FONT_BODY = "Nunito"
local FONT_MONO = "JetBrains Mono"
local space_top = Color.FromHex("#0b0a2e")
local space_bottom = Color.FromHex("#241050")
local dosblue = Color.FromHex("#2e2ecc")
local navy_outline = Color.FromHex("#101040")
local ink = Color.FromHex("#0c0c14")
local paper = Color(1, 1, 1, 1)
local term_green = Color.FromHex("#40ff60")
local select_pink = Color.FromHex("#ff2f6d")
local gold = Color.FromHex("#ffcf3f")
local w95_light = Color(1, 1, 1, 1)
local w95_dark = Color.FromHex("#6e6e7a")
local w95_fill = Color.FromHex("#d4d4dc")
local hot_magenta = Color.FromHex("#ff2fd0")
local hot_cyan = Color.FromHex("#00e5ff")
local hot_lime = Color.FromHex("#b0ff20")
local hot_orange = Color.FromHex("#ff8a1f")
local hot_red = Color.FromHex("#ff3030")
local hot_purple = Color.FromHex("#c030e0")
local surface_navy = Color.FromHex("#14123a")
local surface_alt_navy = Color.FromHex("#1d1a4e")
local surface_deep = Color.FromHex("#100e33")
local disabled_gray = Color.FromHex("#8a8a96")
local RAINBOW = {"#ff3030", "#ffa020", "#ffe020", "#40d040", "#30a0ff", "#6040e0", "#c030e0"}
-- Button color tokens that get the colorful arcade treatment; everything
-- else falls back to the silver Win95 chrome button.
local ARCADA_TOKENS = {
	primary = true,
	secondary = true,
	gold = true,
	positive = true,
	negative = true,
	neutral = true,
	purple = true,
}
local ARCADA_GRADIENTS = {
	primary = {top = "#ffb0ec", bottom = "#d010a0", edge = "#700858"},
	secondary = {top = "#d0fbff", bottom = "#0090c0", edge = "#004858"},
	gold = {top = "#fff6c0", bottom = "#d96a00", edge = "#683800"},
	positive = {top = "#d8ffc0", bottom = "#40a800", edge = "#184800"},
	negative = {top = "#ffb0b0", bottom = "#d02020", edge = "#580808"},
	neutral = {top = "#fff6c0", bottom = "#d96a00", edge = "#683800"},
	purple = {top = "#e0c0ff", bottom = "#8030d0", edge = "#380858"},
}

function PlayfulTheme:CreatePalette()
	return self:ConfigurePalette(self.BaseClass.CreatePalette(self))
end

function PlayfulTheme:ConfigurePalette(palette)
	palette:SetShades{
		paper,
		Color.FromHex("#8fa8c8"),
		ink,
	}
	palette:SetColors{
		red = hot_red,
		yellow = gold,
		blue = dosblue,
		green = hot_lime,
		purple = hot_purple,
		brown = Color.FromHex("#8b5e3c"),
	}
	palette.AdjustmentOptions = self:MergeTables(palette.AdjustmentOptions, {target_contrast = 4.5})
	palette:SetMap{
		primary = hot_magenta,
		primary_focus = Color.FromHex("#d018a8"),
		secondary = hot_cyan,
		gold = gold,
		positive = hot_lime,
		neutral = gold,
		negative = hot_red,
		ink = ink,
		paper = paper,
		dosblue = dosblue,
		term_green = term_green,
		select_pink = select_pink,
		w95_fill = w95_fill,
		w95_dark = w95_dark,
		heading = paper,
		default = paper,
		text = paper,
		text_foreground = paper,
		text_button = paper,
		text_on_accent = ink,
		text_on_dark = paper,
		text_on_dark_muted = paper:Copy():SetAlpha(0.8),
		text_disabled = paper:Copy():SetAlpha(0.4),
		text_on_surface = paper,
		text_on_surface_variant = paper,
		text_on_card = paper,
		text_on_header_surface = paper,
		text_foreground_on_surface = paper,
		text_foreground_on_header_surface = paper,
		heading_on_surface = paper,
		heading_on_header_surface = paper,
		foreground = paper,
		background = space_top,
		main_background = space_top,
		surface = surface_navy,
		surface_alt = surface_alt_navy,
		surface_variant = surface_deep,
		surface_pearl = Color.FromHex("#0f192c"),
		surface_tile_1 = surface_deep,
		surface_tile_2 = surface_navy,
		surface_tile_3 = space_top,
		card = surface_navy,
		header_surface = dosblue,
		track = paper,
		button_color = w95_fill,
		button_normal = w95_fill,
		clickable_disabled = disabled_gray,
		scrollbar_track = Color.FromHex("#0a0926"),
		scrollbar = w95_fill,
		border = w95_dark,
		border_strong = ink,
		property_selection = select_pink,
		text_selection = select_pink:Copy():SetAlpha(0.8),
		actual_black = ink,
		invisible = Color(0, 0, 0, 0),
	}
	return palette
end

function PlayfulTheme:Initialize()
	self.BaseClass.Initialize(self)
	self:SetSizes(
		self:MergeTables(
			self:GetSizes(),
			{
				XXS = 4,
				S = 8,
				M = 12,
				L = 16,
				XL = 24,
				XXL = 32,
				default = 12,
			}
		)
	)
	self:SetRadii(
		self:MergeTables(
			self:GetRadii(),
			{
				none = 0,
				XS = 0,
				S = 0,
				M = 0,
				L = 0,
			}
		)
	)
	self:SetFontSizes(
		self:MergeTables(
			self:GetFontSizes(),
			{
				XS = 11,
				S = 13,
				M = 15,
				L = 20,
				XL = 26,
				XXL = 34,
				XXXL = 48,
			}
		)
	)
	self:SetFontStyles(
		self:MergeTables(
			self:GetFontStyles(),
			{
				heading = {Name = FONT_HEADING, Weight = "Regular"},
				body_weak = {Name = FONT_BODY, Weight = "Regular"},
				body = {Name = FONT_BODY, Weight = "SemiBold"},
				body_strong = {Name = FONT_BODY, Weight = "ExtraBold"},
				mono = {Name = FONT_MONO, Weight = "Bold"},
			}
		)
	)
	self:SetFontCache({})
	self.Textures = nil
end

local function make_textures()
	local function pat(config)
		local t = Texture.New{
			width = config.w or 16,
			height = config.h or 16,
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
		t:Shade(config.glsl)
		return t
	end

	-- subtle 45deg pinstripes, 4px period (seamless: x+y is periodic on the tile)
	local pinstripe = pat{
		glsl = [[
		float s = step(0.5, fract((uv.x + uv.y) * 4.0));
		return vec4(vec3(mix(0.84, 1.0, s)), 1.0);
	]],
	}
	-- dot grid, 4px period
	local dots = pat{
		glsl = [[
		float d = length(fract(uv * 4.0) - 0.5);
		float s = step(d, 0.16);
		return vec4(vec3(mix(0.8, 1.0, s)), 1.0);
	]],
	}
	-- fine checker, 2px cells
	local check = pat{
		glsl = [[
		float s = mod(floor(uv.x * 8.0) + floor(uv.y * 8.0), 2.0);
		return vec4(vec3(mix(0.88, 1.0, s)), 1.0);
	]],
	}
	-- bold diagonal stripes, 8px period, strong contrast
	local stripes = pat{
		glsl = [[
		float s = step(0.5, fract((uv.x + uv.y) * 2.0));
		return vec4(vec3(mix(0.68, 1.0, s)), 1.0);
	]],
	}
	-- chevron / zigzag, 8px period
	local zigzag = pat{
		glsl = [[
		float v = fract(uv.y * 2.0 + abs(fract(uv.x * 2.0) - 0.5));
		float s = step(0.5, v);
		return vec4(vec3(mix(0.78, 1.0, s)), 1.0);
	]],
	}
	-- brushed metal: 16 horizontal noise rows (periodic in y so the tile seams)
	local brushed = pat{
		w = 32,
		h = 16,
		glsl = [[
		float row = floor(uv.y * 16.0);
		float n = fract(sin(row * 1.1781 * 3.0) * 43758.5453);
		float fine = 0.85 + 0.15 * sin(uv.x * 90.0 + n * 6.28);
		return vec4(vec3(mix(0.78, 1.0, n) * fine), 1.0);
	]],
	}
	-- crt scanlines, 2px period
	local scanlines = pat{
		w = 8,
		h = 4,
		glsl = [[
		float s = step(0.5, fract(uv.y * 2.0));
		return vec4(vec3(mix(0.75, 1.0, s)), 1.0);
	]],
	}
	-- subtle 16px grid for window body
	local grid = pat{
		w = 32,
		h = 32,
		glsl = [[
		vec2 f = fract(uv * 2.0);
		float g = min(f.x, f.y) < 0.05 ? 1.0 : 0.0;
		return vec4(vec3(mix(1.0, 0.86, g)), 1.0);
	]],
	}
	-- starfield with a few hot stars
	local starfield = Texture.New{
		width = 1024,
		height = 576,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	starfield:Shade([[
		vec2 p = uv * vec2(24.0, 13.5);
		vec2 cell = floor(p);
		vec2 f = fract(p) - 0.5;
		float h = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
		float h2 = fract(h * 731.7);
		vec2 sp = (vec2(fract(h * 12.3), fract(h * 45.7)) - 0.5) * 0.85;
		float d = length(f - sp);
		float star = smoothstep(0.06, 0.0, d) * step(0.5, h);
		float big = smoothstep(0.16, 0.0, d) * step(0.9, h) * 0.4;
		vec3 hot = h2 > 0.8 ? vec3(1.0, 0.3, 0.85) : (h2 > 0.6 ? vec3(0.3, 0.9, 1.0) : vec3(0.85, 0.9, 1.0));
		vec3 bg = mix(vec3(0.035, 0.025, 0.14), vec3(0.10, 0.04, 0.26), uv.y);
		float neb = 0.5 + 0.5 * sin(uv.x * 8.2 + 1.3) * sin(uv.y * 5.1 + 0.4);
		bg += vec3(0.06, 0.02, 0.12) * neb * 0.6;
		vec3 col = bg + hot * star * (0.5 + 0.5 * h2) + vec3(0.6, 0.7, 1.0) * big;
		return vec4(col, 1.0);
	]])
	-- checker ball
	local ball = Texture.New{
		width = 256,
		height = 256,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	ball:Shade([[
		vec2 c = uv - 0.5;
		float r = length(c) * 2.0;
		if (r > 1.0) return vec4(0.0);
		vec3 n = normalize(vec3(c, sqrt(max(1.0 - r * r, 0.0))));
		float lat = asin(clamp(n.y, -1.0, 1.0));
		float lon = atan(n.x, n.z);
		vec2 sc = vec2(lon * 1.0, lat * 1.0);
		float checker = mod(floor(sc.x) + floor(sc.y), 2.0);
		vec3 base = mix(vec3(0.96, 0.96, 0.96), vec3(0.88, 0.13, 0.15), checker);
		vec3 light_dir = normalize(vec3(-0.45, -0.6, 0.66));
		float diff = max(dot(n, light_dir), 0.0);
		float spec = pow(max(dot(normalize(n + light_dir), vec3(0.0, 0.0, 1.0)), 0.0), 28.0);
		vec3 col = base * (0.42 + 0.58 * diff) + vec3(spec) * 0.55;
		float aa = smoothstep(1.0, 0.96, r);
		return vec4(col, aa);
	]])

	local function vgrad(stops)
		return render2d.CreateGradient{
			mode = "linear",
			angle = 0,
			width = 1,
			height = 256,
			stops = stops,
		}
	end

	local chrome_grad = vgrad{
		{pos = 0.0, color = paper},
		{pos = 0.44, color = Color.FromHex("#d8e4ff")},
		{pos = 0.46, color = Color.FromHex("#5878d8")},
		{pos = 0.72, color = Color.FromHex("#2438a0")},
		{pos = 1.0, color = Color.FromHex("#0c1850")},
	}
	local gold_grad = vgrad{
		{pos = 0.0, color = Color.FromHex("#fff6c0")},
		{pos = 0.5, color = Color.FromHex("#ffc21e")},
		{pos = 1.0, color = Color.FromHex("#d96a00")},
	}
	local cyan_grad = vgrad{
		{pos = 0.0, color = Color.FromHex("#eaffff")},
		{pos = 0.5, color = Color.FromHex("#5fe0e8")},
		{pos = 1.0, color = Color.FromHex("#0090c0")},
	}
	local titlebar_grad = render2d.CreateGradient{
		mode = "linear",
		angle = 90,
		stops = {
			{pos = 0.0, color = navy_outline},
			{pos = 0.55, color = dosblue},
			{pos = 1.0, color = Color.FromHex("#5a6ae8")},
		},
	}
	local rainbow_grad = render2d.CreateGradient{
		mode = "linear",
		angle = 90,
		repeat_texture = true,
		stops = {
			{pos = 0.0, color = Color.FromHex("#ff4040")},
			{pos = 0.17, color = Color.FromHex("#ffd040")},
			{pos = 0.34, color = Color.FromHex("#50e050")},
			{pos = 0.5, color = Color.FromHex("#40d0ff")},
			{pos = 0.67, color = Color.FromHex("#6060ff")},
			{pos = 0.83, color = Color.FromHex("#c050ff")},
			{pos = 1.0, color = Color.FromHex("#ff4040")},
		},
	}

	local function btn_grad(top_hex, bottom_hex)
		return vgrad{
			{pos = 0.0, color = Color.FromHex(top_hex)},
			{pos = 1.0, color = Color.FromHex(bottom_hex)},
		}
	end

	local arcade = {}

	for token, spec in pairs(ARCADA_GRADIENTS) do
		arcade[token] = {
			grad = btn_grad(spec.top, spec.bottom),
			edge = Color.FromHex(spec.edge),
		}
	end

	return {
		pinstripe = pinstripe,
		dots = dots,
		check = check,
		stripes = stripes,
		zigzag = zigzag,
		brushed = brushed,
		scanlines = scanlines,
		grid = grid,
		starfield = starfield,
		ball = ball,
		chrome_grad = chrome_grad,
		gold_grad = gold_grad,
		cyan_grad = cyan_grad,
		titlebar_grad = titlebar_grad,
		rainbow_grad = rainbow_grad,
		arcade = arcade,
	}
end

function PlayfulTheme:GetTextures()
	if not self.Textures then self.Textures = make_textures() end

	return self.Textures
end

local function bevel_on(angle, width, opts)
	opts = opts or {}
	local ambient = opts.ambient or 0.55
	render2d.SetLighting(true)
	render2d.SetBevelWidth(width)
	render2d.SetBevelHeight(opts.height or 0)
	render2d.SetLightAngle(angle)
	render2d.SetLightShininess(opts.shininess or 14)
	render2d.SetLightColor(1, 1, 1)
	render2d.SetAmbientColor(ambient, ambient, ambient)
end

local function bevel_off()
	render2d.SetLighting(false)
end

-- Hard Win95-style bevel box: 2px light/dark edges + 1px black outer ring.
-- raised = light top-left; sunken inverts. fill can carry a pattern texture.
function PlayfulTheme:DrawHardBox(x, y, w, h, opts)
	opts = opts or {}
	local t = opts.thickness or 2
	local raised = opts.raised ~= false
	local light = raised and w95_light or w95_dark
	local dark = raised and w95_dark or w95_light
	local fill = opts.fill or w95_fill
	local tex = opts.texture
	local layers = {
		{
			color = fill,
			texture = tex or false,
			color_uv = tex and {x = 0, y = 0, w = w / 16, h = h / 16} or nil,
		},
		{x = x, y = y, w = w, h = t, color = light},
		{x = x, y = y, w = t, h = h, color = light},
		{x = x, y = y + h - t, w = w, h = t, color = dark},
		{x = x + w - t, y = y, w = t, h = h, color = dark},
	}

	if opts.ring ~= false then
		table.insert(layers, {color = ink, outline_width = -1})
	end

	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		int = true,
		border_radius = opts.radius or 0,
		layers = layers,
	}
end

-- Hard offset black shadow, no blur.
function PlayfulTheme:DrawHardShadow(x, y, w, h, opts)
	opts = opts or {}
	local off = opts.off or 4
	render2d.DrawShape{
		x = x + off,
		y = y + off,
		w = w,
		h = h,
		color = ink,
		alpha = opts.alpha or 0.85,
		border_radius = opts.radius or 0,
	}
end

-- Silver Win95 chrome button with an optional pattern texture.
function PlayfulTheme:DrawSilverButton(x, y, w, h, opts)
	opts = opts or {}
	local fill = opts.fill or w95_fill
	local tex = opts.texture
	local pressed = opts.pressed or false
	local hovered = opts.hovered or false
	local disabled = opts.disabled or false

	if disabled then
		render2d.DrawShape{
			x = x,
			y = y,
			w = w,
			h = h,
			int = true,
			layers = {
				{color = disabled_gray},
				{color = ink, outline_width = -1},
			},
		}
		return
	end

	local face = fill

	if hovered and not pressed then face = fill:Copy():GetLerped(0.25, paper) end

	self:DrawHardBox(
		x,
		y,
		w,
		h,
		{
			fill = face,
			texture = disabled and false or tex,
			raised = not pressed,
		}
	)
end

-- DK-BALL style colorful beveled button: SDF beveled gradient face, scrolling
-- stripe overlay, dark edge ring, hard offset shadow.
function PlayfulTheme:DrawArcadeButton(x, y, w, h, token, opts)
	opts = opts or {}
	local tex = self:GetTextures()
	local spec = tex.arcade[token] or tex.arcade.primary
	local pressed = opts.pressed or false
	local hovered = opts.hovered or false
	local disabled = opts.disabled or false
	local press = pressed and 1 or 0
	local shadow_off = 4 - press * 3 + (hovered and not pressed and 2 or 0)

	if not disabled then
		self:DrawHardShadow(x, y, w, h, {radius = 8, off = shadow_off})
	end

	local face = paper

	if disabled then
		face = disabled_gray
	elseif pressed then
		face = Color(0.72, 0.72, 0.8, 1)
	elseif hovered then
		face = paper:Copy():GetLerped(0.15, spec.edge)
	end

	if not disabled then
		bevel_on(LIGHT_RAISED, 6, {ambient = 1.15, shininess = 22})
	end

	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		color = face,
		texture = disabled and false or spec.grad,
		border_radius = 8,
	}

	if not disabled then bevel_off() end

	local scroll = (opts.scroll ~= false) and (os.clock() * 0.5) % 1 or 0
	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		border_radius = 8,
		layers = {
			{
				color = paper,
				alpha = disabled and 0.08 or 0.22,
				texture = tex.stripes,
				color_uv = {x = -scroll, y = 0, w = w / 16, h = h / 16},
			},
			{color = disabled and w95_dark or spec.edge, outline_width = -2},
		},
	}
end

-- Seven hard rainbow bands with a black ring.
function PlayfulTheme:DrawRainbowBar(x, y, w, h)
	local layers = {}

	for i, hex in ipairs(RAINBOW) do
		local x0 = x + (i - 1) / #RAINBOW * w
		table.insert(layers, {x = x0, y = y, w = w / #RAINBOW + 0.5, color = Color.FromHex(hex)})
	end

	table.insert(layers, {color = ink, outline_width = -2})
	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		int = true,
		layers = layers,
	}
end

-- Gradient-filled text: style is "chrome", "gold", "cyan" or "rainbow".
function PlayfulTheme:DrawGradientText(text, x, y, size, style, opts)
	opts = opts or {}
	local tex = self:GetTextures()
	local grad = style == "gold" and
		tex.gold_grad or
		style == "cyan" and
		tex.cyan_grad or
		style == "rainbow" and
		tex.rainbow_grad or
		tex.chrome_grad
	local outline_w = opts.outline_width or 3
	local outline_c = opts.outline_color or ink
	local uv = style == "rainbow" and
		{x = 0, y = 0, w = 5, h = 1, r = math.pi / 2} or
		{x = 0, y = 0, w = 1, h = 1}

	if opts.shadow then
		render2d.DrawText{
			text = text,
			x = x + 4,
			y = y + 5,
			font = FONT_HEADING,
			size = size,
			align_x = opts.align_x,
			align_y = opts.align_y,
			foreground_color = ink,
			background_color = Color(0, 0, 0, 0),
		}
	end

	render2d.PushTexture(grad)
	render2d.PushColorUV(uv.x, uv.y, uv.w, uv.h, uv.r or 0)
	render2d.DrawText{
		text = text,
		x = x,
		y = y,
		font = FONT_HEADING,
		size = size,
		align_x = opts.align_x,
		align_y = opts.align_y,
		foreground_color = paper,
		outline_width = outline_w,
		outline_color = outline_c,
		background_color = Color(0, 0, 0, 0),
	}
	render2d.PopColorUV()
	render2d.PopTexture()
end

function PlayfulTheme:DrawCheckerBall(x, y, size)
	local tex = self:GetTextures()
	render2d.DrawShape{
		x = x,
		y = y,
		w = size,
		h = size,
		color = paper,
		texture = tex.ball,
	}
end

do
	-- Resolves the colors for a clickable's current state. Silver chrome
	-- buttons get ink text; arcade buttons get paper text.
	function PlayfulTheme:ResolveButtonStyleContext(state)
		local accent = self:GetColor(state.button_color or "primary")
		local background_token
		local foreground_token
		local fill
		local fill_hover
		local fill_hover_alpha
		local fill_pressed
		local fill_pressed_alpha
		local ring
		local ring_hover
		local ring_alpha
		local menu_fill = self:GetColor("invisible")
		local menu_fill_alpha = 0
		local menu_fill_animated = false

		if state.disabled then
			foreground_token = "text_disabled"

			if state.mode == "outline" then
				background_token = "surface"
				fill = self:GetColor("surface")
				ring = self:GetColor("border")
				ring_alpha = 0.5
			else
				background_token = "clickable_disabled"
				fill = self:GetColor("clickable_disabled")
			end
		elseif state.mode == "text" then
			if state.button_color ~= nil then
				background_token = state.button_color
				foreground_token = state.button_color
			else
				foreground_token = (state.hovered or state.pressed or state.active) and "ink" or "text"
			end

			fill_hover = select_pink
			fill_hover_alpha = 1
			fill_pressed = select_pink
			fill_pressed_alpha = 1
		elseif state.mode == "outline" then
			background_token = "button_color"
			foreground_token = "ink"
			fill = w95_fill
			fill_hover = w95_fill
			fill_hover_alpha = 1
			fill_pressed = w95_fill
			fill_pressed_alpha = 1
			ring = w95_dark
			ring_alpha = 1
		elseif state.mode == "menu" then
			foreground_token = state.selected and "ink" or "text"

			if state.pressed then
				menu_fill = self:GetColor("primary")
				menu_fill_alpha = 0.3
			elseif state.selected then
				menu_fill = select_pink
				menu_fill_alpha = 1
			elseif state.active or state.hovered then
				menu_fill = self:GetColor("primary")
				menu_fill_alpha = 0.15
				menu_fill_animated = true
			end
		else
			background_token = state.button_color or "button_color"
			foreground_token = ARCADA_TOKENS[state.button_color] and "text" or "ink"
			fill = accent
			fill_hover = accent
			fill_hover_alpha = 1
			fill_pressed = accent
			fill_pressed_alpha = 1
			ring = accent
			ring_alpha = 1
		end

		return {
			background_token = background_token,
			foreground_token = foreground_token,
			fill = fill,
			fill_hover = fill_hover,
			fill_hover_alpha = fill_hover_alpha,
			fill_pressed = fill_pressed,
			fill_pressed_alpha = fill_pressed_alpha,
			ring = ring,
			ring_hover = ring_hover,
			ring_alpha = ring_alpha,
			menu_fill = menu_fill,
			menu_fill_alpha = menu_fill_alpha,
			menu_fill_animated = menu_fill_animated,
		}
	end

	function PlayfulTheme:DrawButton(size, state)
		local anim = state.anim or {glow_alpha = 0, press_scale = 0}
		local pressed = (state.pressed or state.active) and not state.disabled
		local hovered = state.hovered and not state.disabled
		local tex = self:GetTextures()

		if state.mode == "menu" then
			return self:DrawMenuButton(size, state)
		elseif state.mode == "text" then
			if hovered or pressed or state.active then
				render2d.DrawShape{
					x = 0,
					y = 0,
					w = size.x,
					h = size.y,
					int = true,
					layers = {
						{color = select_pink},
						{color = ink, outline_width = -1},
					},
				}
			end

			return
		elseif state.mode == "outline" then
			self:DrawSilverButton(
				0,
				0,
				size.x,
				size.y,
				{
					texture = tex.pinstripe,
					pressed = pressed,
					hovered = hovered,
					disabled = state.disabled,
				}
			)
			return
		end

		local token = state.button_color or "button_color"

		if ARCADA_TOKENS[token] then
			self:DrawArcadeButton(
				0,
				0,
				size.x,
				size.y,
				token,
				{
					pressed = pressed,
					hovered = hovered,
					disabled = state.disabled,
					scroll = not state.disabled,
				}
			)
		else
			self:DrawSilverButton(
				0,
				0,
				size.x,
				size.y,
				{
					texture = tex.pinstripe,
					pressed = pressed,
					hovered = hovered,
					disabled = state.disabled,
				}
			)
		end
	end

	function PlayfulTheme:DrawMenuButton(size, state, opts)
		opts = opts or {}
		local anim = state.anim or {glow_alpha = 0}
		local context = self:ResolveButtonStyleContext(state)
		local fill_alpha = context.menu_fill_alpha

		if context.menu_fill_animated then
			fill_alpha = fill_alpha * anim.glow_alpha
		end

		if fill_alpha > 0 then
			render2d.DrawShape{
				x = 0,
				y = 0,
				w = size.x,
				h = size.y,
				int = true,
				layers = {
					{color = context.menu_fill, alpha = fill_alpha},
					{color = ink, outline_width = -1},
				},
			}
		end
	end
end

function PlayfulTheme:DrawSlider(size, state)
	local anim = state.anim or {glow_alpha = 0, knob_scale = 1}
	local tex = self:GetTextures()
	local knob = self:GetSize("M")
	local value = state.value
	local min_value = state.min or 0
	local max_value = state.max or 1
	local span = max_value - min_value
	local normalized = span > 0 and (value - min_value) / span or 0
	normalized = math.clamp(normalized, 0, 1)
	local scale = anim.knob_scale or 1
	local knob_w = knob * scale
	local knob_h = knob * scale

	if state.mode == "2d" then
		local span_x = (state.max.x or 1) - (state.min.x or 0)
		local span_y = (state.max.y or 1) - (state.min.y or 0)
		local nx = span_x > 0 and (value.x - (state.min.x or 0)) / span_x or 0
		local ny = span_y > 0 and (value.y - (state.min.y or 0)) / span_y or 0
		self:DrawHardBox(0, 0, size.x, size.y, {raised = false, fill = paper, thickness = 2})
		local kx = math.clamp(nx, 0, 1) * (size.x - knob_w)
		local ky = math.clamp(ny, 0, 1) * (size.y - knob_h)
		self:DrawSilverButton(kx, ky, knob_w, knob_h, {texture = tex.pinstripe})
		return
	end

	if state.mode == "vertical" then
		local track_w = self:GetSize("XS")
		local track_x = (size.x - track_w) / 2
		self:DrawHardBox(0, 0, size.x, size.y, {raised = false, fill = paper, thickness = 2})
		local ky = knob_h / 2 + normalized * (size.y - knob_h)
		self:DrawSilverButton(track_x - 8, ky, track_w + 16, knob_h, {texture = tex.pinstripe})
		render2d.DrawShape{
			x = size.x / 2 - 2,
			y = ky + 4,
			w = 4,
			h = knob_h - 8,
			int = true,
			color = dosblue,
		}
		return
	end

	local track_h = self:GetSize("XS")
	local track_y = (size.y - track_h) / 2
	self:DrawHardBox(0, 0, size.x, size.y, {raised = false, fill = paper, thickness = 2})
	local kx = knob_w / 2 + normalized * (size.x - knob_w)
	self:DrawSilverButton(kx, track_y - 8, knob_w, track_h + 16, {texture = tex.pinstripe})
	render2d.DrawShape{
		x = kx + knob_w / 2 - 2,
		y = track_y - 4,
		w = 4,
		h = track_h + 8,
		int = true,
		color = dosblue,
	}
end

function PlayfulTheme:DrawProgressBar(size, state, color)
	local value = math.clamp(state.value or 0, 0, 1)
	local c = color == nil and self:GetColor("primary") or self:ResolveSurfaceColor(color)
	local tex = self:GetTextures()
	self:DrawHardBox(0, 0, size.x, size.y, {raised = false, fill = paper, thickness = 2})

	if value > 0 then
		local fill_w = (size.x - 6) * value
		local fill_h = size.y - 6
		local scroll = (os.clock() * 0.25) % 1
		render2d.DrawShape{
			x = 3,
			y = 3,
			w = fill_w,
			h = fill_h,
			int = true,
			color = c,
			texture = tex.stripes,
			color_uv = {x = -scroll, y = 0, w = fill_w / 16, h = fill_h / 16},
		}
	end
end

function PlayfulTheme:DrawCheckbox(size, state)
	local anim = state.anim or {glow_alpha = 0, check_anim = state.value and 1 or 0}
	local box_size = math.max(8, math.min(size.x, size.y) - 2)
	local x = (size.x - box_size) / 2
	local y = (size.y - box_size) / 2
	self:DrawHardBox(x, y, box_size, box_size, {raised = false, fill = paper, thickness = 2})
	local s = anim.check_anim or 0

	if s > 0.01 then
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		self:DrawSVGIcon(
			"check",
			Vec2(box_size, box_size),
			{
				size = box_size * (0.55 + 0.3 * s),
				origin_x = 0.5,
				origin_y = 0.5,
				color = ink:Copy():SetAlpha(math.min(1, s)),
			}
		)
		render2d.PopMatrix()
	end
end

function PlayfulTheme:DrawButtonRadio(size, state)
	local anim = state.anim or {glow_alpha = 0, check_anim = state.value and 1 or 0}
	local box_size = math.max(8, math.min(size.x, size.y) - 2)
	local x = (size.x - box_size) / 2
	local y = (size.y - box_size) / 2
	self:DrawHardBox(x, y, box_size, box_size, {raised = false, fill = paper, thickness = 2})
	local s = anim.check_anim or 0

	if s > 0.01 then
		local dot = box_size * 0.5 * s
		render2d.DrawShape{
			x = x + box_size / 2 - dot / 2,
			y = y + box_size / 2 - dot / 2,
			w = dot,
			h = dot,
			int = true,
			color = ink,
			angle = math.rad(45),
		}
	end
end

function PlayfulTheme:DrawFrame(size, emphasis)
	local tex = self:GetTextures()

	if emphasis >= 3 then
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			int = true,
			layers = {
				{
					color = surface_navy,
					texture = tex.grid,
					color_uv = {x = 0, y = 0, w = size.x / 32, h = size.y / 32},
				},
				{color = ink, outline_width = -1},
			},
		}
	elseif emphasis == 2 then
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			int = true,
			layers = {
				{color = surface_alt_navy},
				{color = ink, outline_width = -1},
			},
		}
	else
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			int = true,
			layers = {
				{color = surface_navy},
				{color = ink, outline_width = -1},
			},
		}
	end
end

function PlayfulTheme:DrawFramePost(size, emphasis)
	local t = 2
	local top_color = emphasis >= 3 and w95_dark or w95_light
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		texture = false,
		int = true,
		layers = {
			{x = 0, y = 0, w = size.x, h = t, color = top_color},
			{x = 0, y = 0, w = t, h = size.y, color = w95_light},
			{x = 0, y = size.y - t, w = size.x, h = t, color = w95_dark},
			{x = size.x - t, y = 0, w = t, h = size.y, color = w95_dark},
			{color = ink, outline_width = -1},
		},
	}
end

function PlayfulTheme:DrawHeader(size, emphasis)
	local tex = self:GetTextures()
	local t = 2
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		int = true,
		layers = {
			{color = paper, texture = tex.titlebar_grad},
			{x = 0, y = 0, w = size.x, h = t, color = w95_light},
			{x = 0, y = 0, w = t, h = size.y, color = w95_light},
			{x = 0, y = size.y - t, w = size.x, h = t, color = w95_dark},
			{x = size.x - t, y = 0, w = t, h = size.y, color = w95_dark},
			{color = ink, outline_width = -1},
		},
	}
end

function PlayfulTheme:DrawSelectionFill(size, color, alpha)
	local resolved = self:ResolveColor(color, color or "primary")

	if resolved.a < 0.5 then
		return self:DrawPanelFill(size, resolved, alpha, 0)
	end

	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		int = true,
		layers = {
			{color = select_pink},
			{color = ink, outline_width = -1},
		},
	}
end

function PlayfulTheme:DrawValueField(size, opts)
	opts = opts or {}

	if opts.state == "editing" then
		self:DrawHardBox(0, 0, size.x, size.y, {raised = false, fill = paper, thickness = 2})
	elseif opts.state == "hovered" then
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			int = true,
			layers = {
				{color = surface_alt_navy, alpha = 0.45},
				{color = ink, outline_width = -1},
			},
		}
	end
end

function PlayfulTheme:DrawSurface(size, color, radius)
	local tex = self:GetTextures()

	if color == "scrollbar_track" then
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			int = true,
			layers = {
				{color = self:GetColor("scrollbar_track")},
				{color = ink, outline_width = -1},
			},
		}
	elseif color == "scrollbar" then
		self:DrawHardBox(0, 0, size.x, size.y, {fill = w95_fill, texture = tex.pinstripe})
	elseif color == nil or color == "surface" or color == "surface_alt" or color == "card" then
		self:DrawHardBox(0, 0, size.x, size.y, {raised = false, fill = paper, thickness = 2})
	else
		self:DrawPanelFill(size, self:ResolveColor(color, "surface"), 1, 0)
	end
end

function PlayfulTheme:DrawDivider(size)
	local horiz = size.x >= size.y
	local dark = w95_dark
	local light = w95_light
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		texture = false,
		int = true,
		layers = horiz and
			{
				{x = 0, y = math.floor(size.y / 2), w = size.x, h = 1, color = dark},
				{x = 0, y = math.floor(size.y / 2) + 1, w = size.x, h = 1, color = light},
			} or
			{
				{x = math.floor(size.x / 2), y = 0, w = 1, h = size.y, color = dark},
				{x = math.floor(size.x / 2) + 1, y = 0, w = 1, h = size.y, color = light},
			},
	}
end

function PlayfulTheme:DrawMenuSpacer(size, vertical)
	self:DrawDivider(size)
end

function PlayfulTheme:DrawMenuContainer(size)
	local tex = self:GetTextures()
	self:DrawHardBox(0, 0, size.x, size.y, {fill = w95_fill, texture = tex.brushed, thickness = 2})
end

function PlayfulTheme:DrawTreeGuideLines(size, meta, opts)
	opts = opts or {}
	local toggle_size = opts.toggle_size or 0
	local guide_step = opts.guide_step or 0
	local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
	local center_y = math.floor(size.y / 2)
	local line_start_x = opts.line_start_x or center_x
	local color = paper:Copy():SetAlpha(0.25)
	local T = 1

	for level = 1, #(meta.continuations or {}) do
		if meta.continuations[level] then
			local x = (level - 1) * guide_step + math.floor(toggle_size / 2)
			render2d.DrawShape{
				x = x,
				y = 0,
				w = T,
				h = size.y,
				color = color,
				texture = false,
				int = true,
			}
		end
	end

	if meta.level > 0 then
		render2d.DrawShape{
			x = center_x,
			y = 0,
			w = T,
			h = center_y + T,
			color = color,
			texture = false,
			int = true,
		}
	end

	if not meta.is_last then
		render2d.DrawShape{
			x = center_x,
			y = center_y,
			w = T,
			h = size.y - center_y,
			color = color,
			texture = false,
			int = true,
		}
	end

	render2d.DrawShape{
		x = line_start_x,
		y = center_y,
		w = math.max(T, size.x - line_start_x),
		h = T,
		color = color,
		texture = false,
		int = true,
	}
	return center_x, center_y
end

function PlayfulTheme:DrawTreeToggle(size, meta, opts)
	opts = opts or {}
	local box_size = opts.box_size or 0
	local toggle_size = opts.toggle_size or box_size
	local center_x, center_y = self:DrawTreeGuideLines(
		size,
		meta,
		{
			toggle_size = toggle_size,
			guide_step = opts.guide_step or 0,
			line_start_x = opts.line_start_x,
		}
	)
	local dx = center_x + 0.5
	local dy = center_y + 0.5
	local tex = self:GetTextures()
	self:DrawSilverButton(dx - box_size / 2, dy - box_size / 2, box_size, box_size, {texture = tex.check})
	self:DrawSVGIcon(
		opts.expanded and "minus" or "plus",
		Vec2(box_size, box_size),
		{
			size = box_size * 0.6,
			origin_x = 0.5,
			origin_y = 0.5,
			color = ink,
		}
	)
end

do
	local function get_button_pivot_target(pnl)
		local mpos = system.GetWindow():GetMousePosition()
		local local_pos = pnl.transform:GlobalToLocal(mpos)
		local size = pnl.transform:GetSize()
		local pivot = local_pos / size
		return -pivot + Vec2(1, 1)
	end

	local function get_button_angle_target(pnl)
		local mpos = system.GetWindow():GetMousePosition()
		local local_pos = pnl.transform:GlobalToLocal(mpos)
		local size = pnl.transform:GetSize()
		local nx = (local_pos.x / size.x) * 2 - 1
		local ny = (local_pos.y / size.y) * 2 - 1
		return Ang3(-ny, nx, 0) * 0.01
	end

	function PlayfulTheme:UpdateButtonAnimations(pnl)
		local state = pnl:GetState()
		state.anim = state.anim or
			{
				glow_alpha = 0,
				press_scale = 0,
				last_hovered = state.hovered or false,
				last_active = false,
				last_tilting = false,
			}
		local anim = state.anim
		local is_active = not state.disabled and
			(
				((
					state.hovered and
					state.pressed
				))
				or
				(
					state.active or
					false
				)
			)
		local is_tilting = is_active

		if is_active ~= anim.last_active then
			if not pnl.animation then
				anim.press_scale = is_active and 1 or 0
				pnl.transform:SetDrawScaleOffset(is_active and (Vec2() + 0.97) or Vec2(1, 1))
			else
				pnl.animation:Animate{
					id = "press_scale",
					get = function()
						return anim.press_scale
					end,
					set = function(value)
						anim.press_scale = value
					end,
					to = is_active and 1 or 0,
					interpolation = (state.pressed and not state.hovered) and "linear" or "inOutSine",
					time = (state.pressed and not state.hovered) and 0.2 or 0.1,
				}
				pnl.animation:Animate{
					id = "DrawScaleOffset",
					get = function()
						return pnl.transform:GetDrawScaleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawScaleOffset(value)
					end,
					to = is_active and (Vec2() + 0.97) or (Vec2(1, 1)),
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 100},
					time = (state.pressed and not state.hovered) and 0.2 or nil,
				}
			end

			anim.last_active = is_active
		end

		if state.hovered ~= anim.last_hovered then
			if not pnl.animation then
				anim.glow_alpha = (state.hovered and not state.disabled) and 1 or 0
			else
				pnl.animation:Animate{
					id = "glow_alpha",
					get = function()
						return anim.glow_alpha
					end,
					set = function(value)
						anim.glow_alpha = value
					end,
					to = (state.hovered and not state.disabled) and 1 or 0,
					interpolation = "inOutSine",
					time = 0.1,
				}
			end

			anim.last_hovered = state.hovered
		end

		if is_tilting ~= anim.last_tilting or is_tilting then
			if not pnl.animation then
				pnl.transform:SetPivot(is_tilting and get_button_pivot_target(pnl) or Vec2(0.5, 0.5))
				pnl.transform:SetDrawAngleOffset(is_tilting and get_button_angle_target(pnl) or Ang3(0, 0, 0))
			else
				pnl.animation:Animate{
					id = "Pivot",
					get = function()
						return pnl.transform:GetPivot()
					end,
					set = function(value)
						pnl.transform:SetPivot(value)
					end,
					to = not is_tilting and
						Vec2(0.5, 0.5) or
						{
							__lsx_value = function(panel)
								return get_button_pivot_target(panel)
							end,
						},
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 10},
					time = is_tilting and 0.3 or 10,
				}
				pnl.animation:Animate{
					id = "DrawAngleOffset",
					get = function()
						return pnl.transform:GetDrawAngleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawAngleOffset(value)
					end,
					to = not is_tilting and
						Ang3(0, 0, 0) or
						{
							__lsx_value = function(panel)
								return get_button_angle_target(panel)
							end,
						},
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 10},
					time = is_tilting and 0.3 or 10,
				}
			end

			anim.last_tilting = is_tilting
		end
	end
end

function PlayfulTheme:DrawMuseum()
	local tex = self:GetTextures()
	local W = system.GetWindow():GetSize()
	local ink_c = self:GetColor("ink")
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = W.x,
		h = W.y,
		color = paper,
		texture = tex.starfield,
	}

	do
		local x, y = 660, 55
		self:DrawGradientText(
			"PLAYFUL",
			x,
			y,
			150,
			"chrome",
			{shadow = true, outline_width = 6, outline_color = navy_outline}
		)
		self:DrawGradientText("a late-90s demoscene theme", x, y + 168, 36, "gold")
		self:DrawRainbowBar(x, y + 207, 600, 16)
	end

	do
		local x, y = 80, 330
		local items = {"GAME", "CONFIG", "CHEAT", "NETPLAY"}
		local bw, gap = 150, 10

		for i, item in ipairs(items) do
			local bx = x + (i - 1) * (bw + gap)
			self:DrawSilverButton(bx, y, bw, 44, {texture = tex.pinstripe})
			render2d.DrawText{
				text = item,
				x = bx + bw / 2,
				y = y + 22,
				align_x = 0.5,
				align_y = 0.5,
				font = FONT_MONO,
				size = 19,
				weight = 800,
				foreground_color = ink_c,
				background_color = Color(0, 0, 0, 0),
			}
		end

		render2d.DrawText{
			text = "hard 2px bevel buttons  (win95 chrome, pinstriped)",
			x = 80,
			y = 392,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
	end

	do
		local x, y, w, h = 80, 420, 640, 520
		self:DrawHardBox(x, y, w, h, {fill = w95_fill, texture = tex.brushed, thickness = 3})
		local pad = 10
		local inner_x = x + pad
		local inner_w = w - pad * 2
		local tb_h = 40
		self:DrawHardBox(
			inner_x,
			y + pad,
			inner_w,
			tb_h,
			{raised = false, fill = w95_fill, texture = tex.brushed}
		)
		render2d.DrawText{
			text = "INPUT DEVICE",
			x = inner_x + 14,
			y = y + pad + tb_h / 2,
			align_y = 0.5,
			font = FONT_MONO,
			size = 20,
			weight = 800,
			foreground_color = ink_c,
			background_color = Color(0, 0, 0, 0),
		}
		self:DrawSilverButton(inner_x + inner_w - 38, y + pad + 4, 30, 30, {texture = tex.check})
		render2d.DrawText{
			text = "X",
			x = inner_x + inner_w - 38 + 15,
			y = y + pad + 4 + 15,
			align_x = 0.5,
			align_y = 0.5,
			font = FONT_MONO,
			size = 18,
			weight = 800,
			foreground_color = ink_c,
			background_color = Color(0, 0, 0, 0),
		}
		local body_y = y + pad + tb_h
		local body_h = h - pad * 2 - tb_h
		render2d.DrawShape{
			x = inner_x,
			y = body_y,
			w = inner_w,
			h = body_h,
			int = true,
			layers = {
				{
					color = dosblue,
					texture = tex.grid,
					color_uv = {x = 0, y = 0, w = inner_w / 32, h = body_h / 32},
				},
				{color = ink, outline_width = -1},
			},
		}
		local tab_y = body_y + 12
		local tabs = {"#1", "#2", "#3", "#4", "#5"}
		local tw = 62

		for i, tab in ipairs(tabs) do
			local tx = inner_x + 10 + (i - 1) * (tw - 6)

			if i == 1 then
				self:DrawSilverButton(tx, tab_y, tw, 34, {fill = paper, texture = tex.pinstripe})
			else
				self:DrawSilverButton(tx, tab_y + 6, tw, 28, {fill = w95_dark, texture = tex.zigzag})
			end

			render2d.DrawText{
				text = tab,
				x = tx + tw / 2,
				y = (i == 1) and tab_y + 17 or tab_y + 6 + 14,
				align_x = 0.5,
				align_y = 0.5,
				font = FONT_MONO,
				size = 17,
				weight = 800,
				foreground_color = i == 1 and ink_c or paper,
				background_color = Color(0, 0, 0, 0),
			}
		end

		render2d.DrawText{
			text = "DEVICE:",
			x = inner_x + 16,
			y = tab_y + 62,
			font = FONT_MONO,
			size = 20,
			weight = 800,
			foreground_color = gold,
			background_color = Color(0, 0, 0, 0),
		}
		local lb_x, lb_y, lb_w, lb_h = inner_x + 16, tab_y + 92, 320, 170
		self:DrawHardBox(lb_x, lb_y, lb_w, lb_h, {raised = false, fill = ink, thickness = 2})
		local items = {"NONE", "KEYBOARD/GAMEPAD", "MOUSE", "JOYSTICK"}
		local row_h = 34

		for i, item in ipairs(items) do
			local ry = lb_y + 8 + (i - 1) * row_h

			if i == 2 then
				render2d.DrawShape{
					x = lb_x + 4,
					y = ry,
					w = lb_w - 8,
					h = row_h - 4,
					int = true,
					layers = {
						{color = select_pink},
						{color = ink, outline_width = -1},
					},
				}
			end

			render2d.DrawText{
				text = item,
				x = lb_x + 14,
				y = ry + (row_h - 4) / 2,
				align_y = 0.5,
				font = FONT_MONO,
				size = 18,
				weight = 700,
				foreground_color = i == 2 and ink_c or term_green,
				background_color = Color(0, 0, 0, 0),
			}
		end

		render2d.DrawShape{
			x = lb_x + 3,
			y = lb_y + 3,
			w = lb_w - 6,
			h = lb_h - 6,
			int = true,
			color = ink,
			alpha = 0.18,
			texture = tex.scanlines,
			color_uv = {x = 0, y = 0, w = (lb_w - 6) / 8, h = (lb_h - 6) / 4},
		}
		local set_x = lb_x + lb_w + 24
		self:DrawSilverButton(set_x, lb_y, 150, 40, {texture = tex.dots})
		render2d.DrawText{
			text = "SET",
			x = set_x + 75,
			y = lb_y + 20,
			align_x = 0.5,
			align_y = 0.5,
			font = FONT_MONO,
			size = 19,
			weight = 800,
			foreground_color = ink_c,
			background_color = Color(0, 0, 0, 0),
		}
		self:DrawSilverButton(set_x, lb_y + 54, 150, 40, {texture = tex.dots})
		render2d.DrawText{
			text = "SET KEYS",
			x = set_x + 75,
			y = lb_y + 54 + 20,
			align_x = 0.5,
			align_y = 0.5,
			font = FONT_MONO,
			size = 19,
			weight = 800,
			foreground_color = ink_c,
			background_color = Color(0, 0, 0, 0),
		}
		local cb_x = inner_x + 16
		local cb_y = lb_y + lb_h + 22
		local cbs = {
			{label = "GAME SPECIFIC", checked = false},
			{label = "TURBO AT 30HZ", checked = true},
		}

		for _, cb in ipairs(cbs) do
			self:DrawHardBox(cb_x, cb_y, 26, 26, {raised = false, fill = paper})

			if cb.checked then
				render2d.DrawText{
					text = "X",
					x = cb_x + 13,
					y = cb_y + 13,
					align_x = 0.5,
					align_y = 0.5,
					font = FONT_MONO,
					size = 18,
					weight = 800,
					foreground_color = ink_c,
					background_color = Color(0, 0, 0, 0),
				}
			end

			render2d.DrawText{
				text = cb.label,
				x = cb_x + 38,
				y = cb_y + 13,
				align_y = 0.5,
				font = FONT_MONO,
				size = 18,
				weight = 700,
				foreground_color = paper,
				background_color = Color(0, 0, 0, 0),
			}
			cb_y = cb_y + 40
		end

		render2d.DrawText{
			text = "beveled window: brushed chrome, tabs, scanline listbox",
			x = 80,
			y = 956,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
	end

	do
		local x, y = 800, 330
		render2d.DrawText{
			text = "colorful beveled buttons  (arcade menu, striped faces)",
			x = x,
			y = y,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
		local bw, bh, gap = 245, 58, 16
		local buttons = {
			{label = "EXPAND", token = "primary", scroll = true},
			{label = "SHRINK", token = "purple", scroll = false},
			{label = "SPLIT", token = "positive", scroll = false},
			{label = "THRU", token = "gold", scroll = true},
		}

		for i, b in ipairs(buttons) do
			local bx = x + ((i - 1) % 2) * (bw + gap)
			local by = y + 30 + math.floor((i - 1) / 2) * (bh + gap)
			self:DrawArcadeButton(bx, by, bw, bh, b.token, {scroll = b.scroll})
			render2d.DrawText{
				text = b.label,
				x = bx + bw / 2 + 2,
				y = by + bh / 2 + 2,
				align_x = 0.5,
				align_y = 0.5,
				font = FONT_HEADING,
				size = 30,
				foreground_color = ink,
				background_color = Color(0, 0, 0, 0),
			}
			render2d.DrawText{
				text = b.label,
				x = bx + bw / 2,
				y = by + bh / 2,
				align_x = 0.5,
				align_y = 0.5,
				font = FONT_HEADING,
				size = 30,
				foreground_color = paper,
				outline_width = 3,
				outline_color = tex.arcade[b.token].edge,
				background_color = Color(0, 0, 0, 0),
			}
		end

		local py = y + 30 + (bh + gap) * 2 + 26
		render2d.DrawText{
			text = "sunken track + striped fill",
			x = x,
			y = py,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
		local pw, ph = 530, 30
		self:DrawHardBox(x, py + 26, pw, ph, {raised = false, fill = paper, thickness = 2})
		local fill_w = pw * 0.68
		local scroll = (os.clock() * 0.25) % 1
		render2d.DrawShape{
			x = x + 4,
			y = py + 30,
			w = fill_w,
			h = ph - 8,
			int = true,
			color = dosblue,
			texture = tex.stripes,
			color_uv = {x = -scroll, y = 0, w = fill_w / 16, h = (ph - 8) / 16},
		}
		local sy = py + 74
		render2d.DrawText{
			text = "beveled slider thumb",
			x = x,
			y = sy,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
		local sw, sh = 530, 30
		self:DrawHardBox(x, sy + 26, sw, sh, {raised = false, fill = paper, thickness = 2})
		local knob_x = x + sw * 0.4
		self:DrawSilverButton(knob_x, sy + 20, 44, 42, {texture = tex.pinstripe})
		render2d.DrawShape{
			x = knob_x + 18,
			y = sy + 28,
			w = 8,
			h = 26,
			int = true,
			color = dosblue,
		}
		local by = sy + 78
		render2d.DrawText{
			text = "textured sphere  (procedural)",
			x = x,
			y = by,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
		self:DrawCheckerBall(x, by + 24, 150)
		local gx = x + 190
		self:DrawGradientText("GOLD RUSH", gx, by + 40, 44, "gold")
		self:DrawGradientText("TURBO", gx, by + 106, 44, "rainbow")
		self:DrawGradientText("3000", gx, by + 172, 44, "cyan")
		render2d.DrawText{
			text = "gradient text: gold / rainbow / cyan",
			x = x,
			y = by + 236,
			font = FONT_BODY,
			size = 17,
			weight = 800,
			foreground_color = Color(0.68, 0.62, 0.9, 0.95),
			background_color = Color(0, 0, 0, 0),
		}
	end

	do
		local y = 980
		self:DrawHardBox(40, y, W.x - 80, 44, {fill = w95_fill, texture = tex.pinstripe, thickness = 2})
		local segments = {
			{label = "READY", w = 200},
			{label = "V1.07", w = 160},
			{label = "NTSC", w = 160},
		}
		local sx = 60

		for _, seg in ipairs(segments) do
			self:DrawHardBox(
				sx,
				y + 8,
				seg.w,
				28,
				{raised = false, fill = w95_fill, texture = tex.check, thickness = 2}
			)
			render2d.DrawText{
				text = seg.label,
				x = sx + 12,
				y = y + 8 + 14,
				align_y = 0.5,
				font = FONT_MONO,
				size = 17,
				weight = 700,
				foreground_color = ink_c,
				background_color = Color(0, 0, 0, 0),
			}
			sx = sx + seg.w + 14
		end

		render2d.DrawText{
			text = "goluwa render2d: patterns + bevels + gradients",
			x = W.x - 60,
			y = y + 22,
			align_x = 1,
			align_y = 0.5,
			font = FONT_MONO,
			size = 17,
			foreground_color = ink_c,
			background_color = Color(0, 0, 0, 0),
		}
	end
end

return PlayfulTheme:Register()
