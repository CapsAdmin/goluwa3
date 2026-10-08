local ffi = require("ffi")
local contact_store = {}
-- Persistent per-contact state of a manifold. The first block survives between steps (warm start
-- impulses, anchors in body space), the rest is rewritten by contact_solver.Prepare every substep.
contact_store.Contact = ffi.typeof([[struct {
	double lax, lay, laz, lbx, lby, lbz;
	double jn, jt1, jt2, rest_total, static_active, v_pre;
	double base_depth, base_sep, sep, rest_speed, rest_impulse, rest_stamp;
	double tx, ty, tz;
	double wpx, wpy, wpz;
	double rax, ray, raz, rbx, rby, rbz;
	double cax, cay, caz, cbx, cby, cbz;
	double wax, way, waz, wbx, wby, wbz;
	double nim, lever;
	double bx, by, bz, n1, n2, speed;
	int has_tangent, has_base, has_sep, feature_key;
}]])
contact_store.Array = ffi.typeof("$[?]", contact_store.Contact)
local Array = contact_store.Array
local MIN_CAPACITY = 4

function contact_store.New(capacity)
	return Array(capacity), capacity
end

-- Returns an array of at least `count` contacts for the manifold's spare buffer.
function contact_store.GetSpare(manifold_data, count)
	local spare = manifold_data.spare_cs

	if spare and manifold_data.spare_capacity >= count then return spare end

	local capacity = math.max(count, MIN_CAPACITY)
	spare = Array(capacity)
	manifold_data.spare_cs = spare
	manifold_data.spare_capacity = capacity
	return spare
end

-- Makes the spare buffer (filled by manifold.RebuildContacts) the current one.
function contact_store.Swap(manifold_data, count)
	manifold_data.cs, manifold_data.spare_cs = manifold_data.spare_cs, manifold_data.cs
	manifold_data.capacity, manifold_data.spare_capacity = manifold_data.spare_capacity, manifold_data.capacity or 0
	manifold_data.n = count
end

return contact_store
