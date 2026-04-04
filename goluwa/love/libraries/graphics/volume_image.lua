return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local line = ctx.line
	local ADD_FILTER = ctx.ADD_FILTER
	local translate_wrap_mode = ctx.translate_wrap_mode
	local VolumeImage = line.TypeTemplate("VolumeImage")
	ADD_FILTER(VolumeImage)

	function VolumeImage:getWidth()
		return self.layer_width or 0
	end

	function VolumeImage:getHeight()
		return self.layer_height or 0
	end

	function VolumeImage:getDepth()
		return self.depth or 0
	end

	function VolumeImage:getDimensions()
		return self:getWidth(), self:getHeight(), self:getDepth()
	end

	function VolumeImage:getData()
		return self.atlas_image_data
	end

	function VolumeImage:setWrap(wrap_s, wrap_t)
		self.wrap_s = wrap_s or self.wrap_s
		self.wrap_t = wrap_t or wrap_s or self.wrap_t
		local tex = ENV.textures[self]
		local translated_wrap_s, border_color_s = translate_wrap_mode(self.wrap_s)
		local translated_wrap_t, border_color_t = translate_wrap_mode(self.wrap_t)
		local translated_wrap_r, border_color_r = translate_wrap_mode(self.wrap_t)
		local border_color = border_color_s or border_color_t or border_color_r

		if not tex then return end

		tex:SetWrapS(translated_wrap_s)
		tex:SetWrapT(translated_wrap_t)
		tex:SetWrapR(translated_wrap_r)

		if border_color ~= nil then tex:SetBorderColor(border_color) end
	end

	function VolumeImage:getWrap()
		return self.wrap_s, self.wrap_t
	end

	local function normalize_volume_layer(layer, index)
		local layer_type = line.Type(layer)

		if layer_type == "ImageData" then return layer end

		if layer_type == "Image" then return layer:getData() end

		if type(layer) == "string" then return love.image.newImageData(layer) end

		error("newVolumeImage layer #" .. index .. " must be ImageData, Image, or a path", 3)
	end

	function love.graphics.newVolumeImage(layers)
		assert(type(layers) == "table", "newVolumeImage requires a table of layers")
		assert(#layers > 0, "newVolumeImage requires at least one layer")
		local normalized_layers = {}
		local layer_width
		local layer_height

		for i = 1, #layers do
			local layer = normalize_volume_layer(layers[i], i)
			local width, height = layer:getDimensions()

			if not layer_width then
				layer_width = width
				layer_height = height
			elseif layer_width ~= width or layer_height ~= height then
				error("newVolumeImage requires all layers to have matching dimensions", 2)
			end

			normalized_layers[i] = layer
		end

		local atlas_image_data = love.image.newImageData(layer_width, layer_height * #normalized_layers)

		for i, layer in ipairs(normalized_layers) do
			atlas_image_data:paste(layer, 0, (i - 1) * layer_height)
		end

		local self = line.CreateObject("VolumeImage")
		self.layer_width = layer_width
		self.layer_height = layer_height
		self.depth = #normalized_layers
		self.atlas_image_data = atlas_image_data
		self.filter_min = "nearest"
		self.filter_mag = "nearest"
		self.filter_anistropy = 1
		self.wrap_s = "clamp"
		self.wrap_t = "clamp"
		ENV.textures[self] = love.image._createTextureFromImageData(
			atlas_image_data,
			{
				min_filter = self.filter_min,
				mag_filter = self.filter_mag,
				anisotropy = self.filter_anistropy,
			}
		)
		self:setWrap(self.wrap_s, self.wrap_t)
		return self
	end

	line.RegisterType(VolumeImage)
end
