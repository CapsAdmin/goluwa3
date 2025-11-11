-- Programmatically generate cube geometry
local function generate_cube(size)
	size = size or 1.0
	local half = size / 2
	-- Define the 6 faces of a cube with their properties
	-- Each face: {normal, positions for 4 corners, UVs for 4 corners}
	local faces = {
		-- Front face (+Z)
		{
			normal = {0, 0, 1},
			positions = {
				{-half, -half, half},
				{half, -half, half},
				{half, half, half},
				{-half, half, half},
			},
		},
		-- Back face (-Z)
		{
			normal = {0, 0, -1},
			positions = {
				{half, -half, -half},
				{-half, -half, -half},
				{-half, half, -half},
				{half, half, -half},
			},
		},
		-- Right face (+X)
		{
			normal = {1, 0, 0},
			positions = {
				{half, -half, half},
				{half, -half, -half},
				{half, half, -half},
				{half, half, half},
			},
		},
		-- Left face (-X)
		{
			normal = {-1, 0, 0},
			positions = {
				{-half, -half, -half},
				{-half, -half, half},
				{-half, half, half},
				{-half, half, -half},
			},
		},
		-- Top face (+Y)
		{
			normal = {0, 1, 0},
			positions = {
				{-half, half, half},
				{half, half, half},
				{half, half, -half},
				{-half, half, -half},
			},
		},
		-- Bottom face (-Y)
		{
			normal = {0, -1, 0},
			positions = {
				{-half, -half, -half},
				{half, -half, -half},
				{half, -half, half},
				{-half, -half, half},
			},
		},
	}
	local uvs = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	local vertices = {}
	local indices = {}
	local vertex_count = 0

	for face_idx, face in ipairs(faces) do
		-- Add 4 vertices for this face
		for i = 1, 4 do
			local pos = face.positions[i]
			local normal = face.normal
			local uv = uvs[i]
			-- Position (vec3)
			table.insert(vertices, pos[1])
			table.insert(vertices, pos[2])
			table.insert(vertices, pos[3])
			-- Normal (vec3)
			table.insert(vertices, normal[1])
			table.insert(vertices, normal[2])
			table.insert(vertices, normal[3])
			-- UV (vec2)
			table.insert(vertices, uv[1])
			table.insert(vertices, uv[2])
		end

		-- Add 6 indices for this face (2 triangles) - counter-clockwise winding
		table.insert(indices, vertex_count + 0)
		table.insert(indices, vertex_count + 1)
		table.insert(indices, vertex_count + 2)
		table.insert(indices, vertex_count + 0)
		table.insert(indices, vertex_count + 2)
		table.insert(indices, vertex_count + 3)
		vertex_count = vertex_count + 4
	end

	return vertices, indices
end

return generate_cube
