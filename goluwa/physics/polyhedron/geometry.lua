local polyhedron_geometry = {}

function polyhedron_geometry.GetEdgeIndices(edge)
	if not edge then return nil, nil end

	return edge.a or edge[1], edge.b or edge[2]
end

function polyhedron_geometry.GetEdgeDirection(polyhedron, edge)
	if not edge then return nil end

	if edge.direction then return edge.direction end

	local a, b = polyhedron_geometry.GetEdgeIndices(edge)
	return a and
		b and
		polyhedron and
		polyhedron.vertices and
		polyhedron.vertices[a] and
		polyhedron.vertices[b] and
		(
			polyhedron.vertices[b] - polyhedron.vertices[a]
		)
		or
		nil
end

return polyhedron_geometry
