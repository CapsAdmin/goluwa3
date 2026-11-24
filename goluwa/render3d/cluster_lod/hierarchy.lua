local ffi = require("ffi")
local sqrt, floor, ceil, max, min, abs = math.sqrt, math.floor, math.ceil, math.max, math.min, math.abs
local clock = os.clock
local CLUSTER_TRIS = 128
local GROUP_CLUSTERS = 16
local ERROR_SCALE = 1.25
local MAX_GROUP_TRIS = GROUP_CLUSTERS * CLUSTER_TRIS
local hierarchy = {}

local function select_nth(ids, key, lo, hi, nth)
	hi = hi - 1

	while lo < hi do
		local pivot = key[ids[floor((lo + hi) / 2)]]
		local i, j = lo, hi

		while i <= j do
			while key[ids[i]] < pivot do
				i = i + 1
			end

			while key[ids[j]] > pivot do
				j = j - 1
			end

			if i <= j then
				ids[i], ids[j] = ids[j], ids[i]
				i = i + 1
				j = j - 1
			end
		end

		if nth <= j then
			hi = j
		elseif nth >= i then
			lo = i
		else
			return
		end
	end
end

local function kd_split(ids, kx, ky, kz, lo, hi, max_items, runs)
	local count = hi - lo
	local k = ceil(count / max_items)

	if k <= 1 then
		runs[#runs + 1] = lo
		runs[#runs + 1] = hi
		return
	end

	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge

	for i = lo, hi - 1 do
		local id = ids[i]
		local x, y, z = kx[id], ky[id], kz[id]

		if x < x0 then x0 = x end

		if x > x1 then x1 = x end

		if y < y0 then y0 = y end

		if y > y1 then y1 = y end

		if z < z0 then z0 = z end

		if z > z1 then z1 = z end
	end

	local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
	local key = dx >= dy and dx >= dz and kx or (dy >= dz and ky or kz)
	local left = floor(count * floor(k / 2) / k + 0.5)
	local nth = lo + left
	select_nth(ids, key, lo, hi, nth)
	kd_split(ids, kx, ky, kz, lo, nth, max_items, runs)
	kd_split(ids, kx, ky, kz, nth, hi, max_items, runs)
end

local function bounding_sphere(mesh, tris, n)
	local mx, my, mz = mesh.x, mesh.y, mesh.z
	local count = n * 3
	local p0 = tris[0]
	local best, p1 = -1, p0

	for i = 0, count - 1 do
		local v = tris[i]
		local dx, dy, dz = mx[v] - mx[p0], my[v] - my[p0], mz[v] - mz[p0]
		local d = dx * dx + dy * dy + dz * dz

		if d > best then best, p1 = d, v end
	end

	best = -1
	local p2 = p1

	for i = 0, count - 1 do
		local v = tris[i]
		local dx, dy, dz = mx[v] - mx[p1], my[v] - my[p1], mz[v] - mz[p1]
		local d = dx * dx + dy * dy + dz * dz

		if d > best then best, p2 = d, v end
	end

	local cx, cy, cz = (mx[p1] + mx[p2]) / 2, (my[p1] + my[p2]) / 2, (mz[p1] + mz[p2]) / 2
	local r = sqrt(best) / 2

	for _ = 1, 2 do
		for i = 0, count - 1 do
			local v = tris[i]
			local dx, dy, dz = mx[v] - cx, my[v] - cy, mz[v] - cz
			local d = sqrt(dx * dx + dy * dy + dz * dz)

			if d > r then
				local new_r = (r + d) / 2
				local t = (new_r - r) / d
				cx, cy, cz, r = cx + dx * t, cy + dy * t, cz + dz * t, new_r
			end
		end
	end

	return {cx, cy, cz, r * (1 + 1e-9) + 1e-12}
end

local function make_clusters(mesh, tris, n, level, out, isl)
	local cx, cy, cz = ffi.new("double[?]", n), ffi.new("double[?]", n), ffi.new("double[?]", n)
	local ids = ffi.new("int32_t[?]", n)
	local mx, my, mz = mesh.x, mesh.y, mesh.z

	for t = 0, n - 1 do
		local a, b, c = tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]
		cx[t] = (mx[a] + mx[b] + mx[c]) / 3
		cy[t] = (my[a] + my[b] + my[c]) / 3
		cz[t] = (mz[a] + mz[b] + mz[c]) / 3
		ids[t] = t
	end

	local runs = {}
	kd_split(ids, cx, cy, cz, 0, n, CLUSTER_TRIS, runs)
	local made = {}

	for r = 1, #runs, 2 do
		local lo, hi = runs[r], runs[r + 1]
		local count = hi - lo
		local ctris = ffi.new("uint32_t[?]", count * 3)

		for i = 0, count - 1 do
			local t = ids[lo + i]
			ctris[i * 3], ctris[i * 3 + 1], ctris[i * 3 + 2] = tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]
		end

		local cisl

		if isl then
			cisl = ffi.new("uint32_t[?]", count)

			for i = 0, count - 1 do
				cisl[i] = isl[ids[lo + i]]
			end
		end

		local cluster = {
			n = count,
			tris = ctris,
			isl = cisl,
			level = level,
			id = #out + 1,
			err_self = 0,
			err_parent = math.huge,
		}
		out[#out + 1] = cluster
		made[#made + 1] = cluster
	end

	return made
end

local function point_tri_dist2(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz)
	local abx, aby, abz = bx - ax, by - ay, bz - az
	local acx, acy, acz = cx - ax, cy - ay, cz - az
	local apx, apy, apz = px - ax, py - ay, pz - az
	local d1, d2 = abx * apx + aby * apy + abz * apz, acx * apx + acy * apy + acz * apz
	local qx, qy, qz

	if d1 <= 0 and d2 <= 0 then
		qx, qy, qz = ax, ay, az
	else
		local bpx, bpy, bpz = px - bx, py - by, pz - bz
		local d3, d4 = abx * bpx + aby * bpy + abz * bpz, acx * bpx + acy * bpy + acz * bpz

		if d3 >= 0 and d4 <= d3 then
			qx, qy, qz = bx, by, bz
		else
			local vc = d1 * d4 - d3 * d2

			if vc <= 0 and d1 >= 0 and d3 <= 0 then
				local v = d1 / (d1 - d3)
				qx, qy, qz = ax + v * abx, ay + v * aby, az + v * abz
			else
				local cpx, cpy, cpz = px - cx, py - cy, pz - cz
				local d5, d6 = abx * cpx + aby * cpy + abz * cpz, acx * cpx + acy * cpy + acz * cpz

				if d6 >= 0 and d5 <= d6 then
					qx, qy, qz = cx, cy, cz
				else
					local vb = d5 * d2 - d1 * d6

					if vb <= 0 and d2 >= 0 and d6 <= 0 then
						local w = d2 / (d2 - d6)
						qx, qy, qz = ax + w * acx, ay + w * acy, az + w * acz
					else
						local va = d3 * d6 - d5 * d4

						if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
							local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
							qx, qy, qz = bx + w * (cx - bx), by + w * (cy - by), bz + w * (cz - bz)
						else
							local denom = 1 / (va + vb + vc)
							local v, w = vb * denom, vc * denom
							qx, qy, qz = ax + abx * v + acx * w, ay + aby * v + acy * w, az + abz * v + acz * w
						end
					end
				end
			end
		end
	end

	local dx, dy, dz = px - qx, py - qy, pz - qz
	return dx * dx + dy * dy + dz * dz, qx, qy, qz
end

local MAXT = MAX_GROUP_TRIS + 64
local MAXV = MAXT * 3
local SLOTS = MAXT * 16
local HEAP = 1 << 18
local S = {
	gid = ffi.new("int32_t[?]", MAXV),
	lock = ffi.new("uint8_t[?]", MAXV),
	valive = ffi.new("uint8_t[?]", MAXV),
	q = ffi.new("double[?]", MAXV * 10),
	qw = ffi.new("double[?]", MAXV),
	ver = ffi.new("int32_t[?]", MAXV),
	dev = ffi.new("double[?]", MAXV),
	vhead = ffi.new("int32_t[?]", MAXV),
	slot_next = ffi.new("int32_t[?]", SLOTS),
	slot_tri = ffi.new("int32_t[?]", SLOTS),
	ta = ffi.new("int32_t[?]", MAXT),
	tb = ffi.new("int32_t[?]", MAXT),
	tc = ffi.new("int32_t[?]", MAXT),
	talive = ffi.new("uint8_t[?]", MAXT),
	tseen = ffi.new("int32_t[?]", MAXT),
	mark1 = ffi.new("int32_t[?]", MAXV),
	mark2 = ffi.new("int32_t[?]", MAXV),
	mark3 = ffi.new("int32_t[?]", MAXV),
	scratch = ffi.new("int32_t[?]", 4096),
	scratch2 = ffi.new("int32_t[?]", 4096),
	tisl = ffi.new("int32_t[?]", MAXT),
	vi = ffi.new("int32_t[?]", MAXV * 4),
	vw = ffi.new("int32_t[?]", MAXV * 4),
	vic = ffi.new("uint8_t[?]", MAXV),
	udev = ffi.new("double[?]", MAXV),
	bdev = ffi.new("double[?]", MAXV),
	bb = ffi.new("double[24]"),
	ndev = ffi.new("double[?]", MAXV),
	bd = ffi.new("double[4]"),
	bu = ffi.new("double[4]"),
	bv = ffi.new("double[4]"),
	bnx = ffi.new("double[4]"),
	bny = ffi.new("double[4]"),
	bnz = ffi.new("double[4]"),
	bok = ffi.new("uint8_t[4]"),
	hcost = ffi.new("double[?]", HEAP),
	hfrom = ffi.new("int32_t[?]", HEAP),
	hto = ffi.new("int32_t[?]", HEAP),
	hvf = ffi.new("int32_t[?]", HEAP),
	hvt = ffi.new("int32_t[?]", HEAP),
}
local stamp = 0
local vdev, vdev_new
local tstamp = 0
local local_of
local UV_TOL = 0.01
local NORMAL_TOL = 0.35
local BEND_TOL = 0.15
local BEND_VALUES = 6
local vuv, vuv_new, vnd, vnd_new, vbd, vbd_new
local vshared, vowner

local function simplify(mesh, tris, isl, nt, target, stats, mode)
	assert(nt <= MAXT, "group too big")
	mode = mode or 0
	local hardlock = mesh.hardlock
	local uv_tol = mode == 0 and UV_TOL or UV_TOL * 4
	local normal_tol = mode == 0 and NORMAL_TOL or NORMAL_TOL * 2
	local attrs = mesh.wlookup ~= nil
	local nisl = mesh.nisl
	local wlookup = mesh.wlookup
	local wu, wv, wnx, wny, wnz = mesh.wu, mesh.wv, mesh.wnx, mesh.wny, mesh.wnz
	local lockpos = mesh.lockpos
	local mx, my, mz = mesh.x, mesh.y, mesh.z
	local gid, lock, valive, q, qw, ver, vhead, dev = S.gid, S.lock, S.valive, S.q, S.qw, S.ver, S.vhead, S.dev
	local slot_next, slot_tri, ta, tb, tc, talive, tseen = S.slot_next, S.slot_tri, S.ta, S.tb, S.tc, S.talive, S.tseen
	local mark1, mark2, mark3, scratch, scratch2 = S.mark1, S.mark2, S.mark3, S.scratch, S.scratch2
	local hcost, hfrom, hto, hvf, hvt = S.hcost, S.hfrom, S.hto, S.hvf, S.hvt
	local tisl, vi, vw, vic, udev, ndev = S.tisl, S.vi, S.vw, S.vic, S.udev, S.ndev
	local bd, bu, bv, bnx, bny, bnz, bok = S.bd, S.bu, S.bv, S.bnx, S.bny, S.bnz, S.bok
	local bdev, bb, wbend = S.bdev, S.bb, mesh.wbend
	local nv = 0
	local slots = 0

	for t = 0, nt - 1 do
		local ti = attrs and isl[t] or 0
		tisl[t] = ti

		for k = 0, 2 do
			local g = tris[t * 3 + k]
			local l = local_of[g]

			if l < 0 then
				l = nv
				nv = nv + 1
				local_of[g] = l
				gid[l] = g
				valive[l] = 1
				lock[l] = (
						(
							hardlock and
							hardlock[g] == 1
						)
						or
						(
							mode < 2 and
							lockpos and
							lockpos[g]
						)
					)
					and
					1 or
					0
				ver[l] = 0
				vhead[l] = -1
				qw[l] = 0
				dev[l] = vdev[g]
				udev[l] = vuv[g]
				bdev[l] = vbd[g]
				ndev[l] = vnd[g]
				vic[l] = 0

				for c = 0, 9 do
					q[l * 10 + c] = 0
				end
			end

			if attrs then
				local count = vic[l]
				local found = false

				for j = 0, count - 1 do
					if vi[l * 4 + j] == ti then
						found = true

						break
					end
				end

				if not found then
					if count < 4 then
						vi[l * 4 + count] = ti
						vw[l * 4 + count] = wlookup[g * nisl + ti] or -1
						vic[l] = count + 1
					elseif mode < 2 then
						lock[l] = 1
					end
				end
			end

			if k == 0 then ta[t] = l elseif k == 1 then tb[t] = l else tc[t] = l end
		end

		talive[t] = 1
		tseen[t] = 0
	end

	for t = 0, nt - 1 do
		for k = 0, 2 do
			local v = k == 0 and ta[t] or (k == 1 and tb[t] or tc[t])
			slot_tri[slots] = t
			slot_next[slots] = vhead[v]
			vhead[v] = slots
			slots = slots + 1
		end
	end

	local edges = {}

	for t = 0, nt - 1 do
		local a, b, c = ta[t], tb[t], tc[t]
		local pa, pb, pc = gid[a], gid[b], gid[c]
		local e1x, e1y, e1z = mx[pb] - mx[pa], my[pb] - my[pa], mz[pb] - mz[pa]
		local e2x, e2y, e2z = mx[pc] - mx[pa], my[pc] - my[pa], mz[pc] - mz[pa]
		local nx, ny, nz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
		local len = sqrt(nx * nx + ny * ny + nz * nz)

		if len > 0 then
			local area = len * 0.5
			nx, ny, nz = nx / len, ny / len, nz / len
			local d = -(nx * mx[pa] + ny * my[pa] + nz * mz[pa])

			for k = 0, 2 do
				local v = k == 0 and a or (k == 1 and b or c)
				local o = v * 10
				q[o] = q[o] + area * nx * nx
				q[o + 1] = q[o + 1] + area * nx * ny
				q[o + 2] = q[o + 2] + area * nx * nz
				q[o + 3] = q[o + 3] + area * ny * ny
				q[o + 4] = q[o + 4] + area * ny * nz
				q[o + 5] = q[o + 5] + area * nz * nz
				q[o + 6] = q[o + 6] + area * d * nx
				q[o + 7] = q[o + 7] + area * d * ny
				q[o + 8] = q[o + 8] + area * d * nz
				q[o + 9] = q[o + 9] + area * d * d
				qw[v] = qw[v] + area
			end
		end

		for k = 0, 2 do
			local u = k == 0 and a or (k == 1 and b or c)
			local w = k == 0 and b or (k == 1 and c or a)
			local key = min(u, w) * 8192 + max(u, w)
			edges[key] = (edges[key] or 0) + 1
		end
	end

	for key, count in pairs(edges) do
		if count ~= 2 then
			local u, w = floor(key / 8192), key % 8192

			if mode == 0 or count > 2 then
				lock[u] = 1
				lock[w] = 1
			else
				if vshared[gid[u]] == 1 then lock[u] = 1 end

				if vshared[gid[w]] == 1 then lock[w] = 1 end
			end
		end
	end

	local heap_size = 0

	local function heap_push(cost, from, to)
		assert(heap_size < HEAP - 1, "heap full")
		local i = heap_size
		heap_size = heap_size + 1

		while i > 0 do
			local p = floor((i - 1) / 2)

			if hcost[p] <= cost then break end

			hcost[i], hfrom[i], hto[i], hvf[i], hvt[i] = hcost[p], hfrom[p], hto[p], hvf[p], hvt[p]
			i = p
		end

		hcost[i], hfrom[i], hto[i], hvf[i], hvt[i] = cost, from, to, ver[from], ver[to]
	end

	local function heap_pop()
		local cost, from, to, vf, vt = hcost[0], hfrom[0], hto[0], hvf[0], hvt[0]
		heap_size = heap_size - 1
		local last_cost, last_from, last_to, last_vf, last_vt = hcost[heap_size], hfrom[heap_size], hto[heap_size], hvf[heap_size], hvt[heap_size]
		local i = 0

		while true do
			local c = i * 2 + 1

			if c >= heap_size then break end

			if c + 1 < heap_size and hcost[c + 1] < hcost[c] then c = c + 1 end

			if hcost[c] >= last_cost then break end

			hcost[i], hfrom[i], hto[i], hvf[i], hvt[i] = hcost[c], hfrom[c], hto[c], hvf[c], hvt[c]
			i = c
		end

		if heap_size > 0 then
			hcost[i], hfrom[i], hto[i], hvf[i], hvt[i] = last_cost, last_from, last_to, last_vf, last_vt
		end

		return cost, from, to, vf, vt
	end

	local function eval(a, b, p)
		local oa, ob = a * 10, b * 10
		local px, py, pz = mx[gid[p]], my[gid[p]], mz[gid[p]]
		local a00, a01, a02 = q[oa] + q[ob], q[oa + 1] + q[ob + 1], q[oa + 2] + q[ob + 2]
		local a11, a12, a22 = q[oa + 3] + q[ob + 3], q[oa + 4] + q[ob + 4], q[oa + 5] + q[ob + 5]
		local b0, b1, b2, c = q[oa + 6] + q[ob + 6],
		q[oa + 7] + q[ob + 7],
		q[oa + 8] + q[ob + 8],
		q[oa + 9] + q[ob + 9]
		local e = a00 * px * px + 2 * a01 * px * py + 2 * a02 * px * pz + a11 * py * py + 2 * a12 * py * pz + a22 * pz * pz + 2 * (
				b0 * px + b1 * py + b2 * pz
			) + c
		local w = qw[a] + qw[b]
		return w > 0 and max(e, 0) / w or 0
	end

	local function push_edge(a, b)
		local best, from, to = math.huge
		local lock_a, lock_b = lock[a] == 1, lock[b] == 1

		if lock_a and lock_b then return end

		if not lock_a then best, from, to = eval(a, b, b), a, b end

		if not lock_b then
			local c = eval(a, b, a)

			if c < best then best, from, to = c, b, a end
		end

		heap_push(best, from, to)
	end

	local function gather(v, out)
		tstamp = tstamp + 1
		local count = 0
		local s = vhead[v]

		while s >= 0 do
			local t = slot_tri[s]

			if
				talive[t] == 1 and
				tseen[t] ~= tstamp and
				(
					ta[t] == v or
					tb[t] == v or
					tc[t] == v
				)
			then
				tseen[t] = tstamp
				out[count] = t
				count = count + 1
			end

			s = slot_next[s]
		end

		return count
	end

	local function wedge_in(l, island)
		for j = 0, vic[l] - 1 do
			if vi[l * 4 + j] == island then return vw[l * 4 + j] end
		end

		return -1
	end

	local fx, fy, fz, pe_d2, pe_from

	local function consider(a, b, c, island)
		local pa, pb, pc = gid[a], gid[b], gid[c]
		local ax, ay, az, bx, by, bz, cx, cy, cz = mx[pa], my[pa], mz[pa], mx[pb], my[pb], mz[pb], mx[pc], my[pc], mz[pc]
		local dd, qx, qy, qz = point_tri_dist2(fx, fy, fz, ax, ay, az, bx, by, bz, cx, cy, cz)

		if dd < pe_d2 then pe_d2 = dd end

		if not attrs then return end

		for j = 0, vic[pe_from] - 1 do
			if vi[pe_from * 4 + j] == island and dd < bd[j] then
				bd[j] = dd
				local v0x, v0y, v0z = bx - ax, by - ay, bz - az
				local v1x, v1y, v1z = cx - ax, cy - ay, cz - az
				local v2x, v2y, v2z = qx - ax, qy - ay, qz - az
				local d00, d01, d11 = v0x * v0x + v0y * v0y + v0z * v0z,
				v0x * v1x + v0y * v1y + v0z * v1z,
				v1x * v1x + v1y * v1y + v1z * v1z
				local d20, d21 = v2x * v0x + v2y * v0y + v2z * v0z, v2x * v1x + v2y * v1y + v2z * v1z
				local denom = d00 * d11 - d01 * d01
				local u1, w1 = 0, 0

				if abs(denom) > 1e-30 then
					u1 = (d11 * d20 - d01 * d21) / denom
					w1 = (d00 * d21 - d01 * d20) / denom
				end

				local u0 = 1 - u1 - w1
				local wa, wb, wc = wedge_in(a, island), wedge_in(b, island), wedge_in(c, island)

				if wa >= 0 and wb >= 0 and wc >= 0 then
					bok[j] = 1
					bu[j] = u0 * wu[wa] + u1 * wu[wb] + w1 * wu[wc]
					bv[j] = u0 * wv[wa] + u1 * wv[wb] + w1 * wv[wc]
					bnx[j] = u0 * wnx[wa] + u1 * wnx[wb] + w1 * wnx[wc]
					bny[j] = u0 * wny[wa] + u1 * wny[wb] + w1 * wny[wc]
					bnz[j] = u0 * wnz[wa] + u1 * wnz[wb] + w1 * wnz[wc]

					if wbend then
						for k = 0, BEND_VALUES - 1 do
							bb[j * BEND_VALUES + k] = u0 * wbend[wa * BEND_VALUES + k] + u1 * wbend[wb * BEND_VALUES + k] + w1 * wbend[wc * BEND_VALUES + k]
						end
					end
				else
					bok[j] = 0
				end
			end
		end
	end

	for t = 0, nt - 1 do
		local a, b, c = ta[t], tb[t], tc[t]

		if a < b then push_edge(a, b) end

		if b < c then push_edge(b, c) end

		if c < a then push_edge(c, a) end
	end

	local tri_count = nt
	local err_max = 0
	local collapses, rejected, attr_rejected, seam_collapses = 0, 0, 0, 0

	while tri_count > target and heap_size > 0 do
		local cost, from, to, vf, vt = heap_pop()

		if valive[from] == 1 and valive[to] == 1 and ver[from] == vf and ver[to] == vt then
			local ok = true
			stamp = stamp + 1
			local count_to = gather(to, scratch2)

			for i = 0, count_to - 1 do
				local t = scratch2[i]
				mark1[ta[t]], mark1[tb[t]], mark1[tc[t]] = stamp, stamp, stamp
			end

			local count_from = gather(from, scratch)
			local shared, both = 0, 0
			local new_locked_edge = false

			for i = 0, count_from - 1 do
				local t = scratch[i]
				local a, b, c = ta[t], tb[t], tc[t]

				if a == to or b == to or c == to then both = both + 1 end

				for k = 0, 2 do
					local v = k == 0 and a or (k == 1 and b or c)

					if v ~= from and v ~= to and mark1[v] == stamp and mark2[v] ~= stamp then
						mark2[v] = stamp
						shared = shared + 1
					end

					if v ~= from and v ~= to and mark1[v] ~= stamp and lock[v] == 1 and lock[to] == 1 then
						new_locked_edge = true
					end
				end
			end

			if shared ~= both or new_locked_edge then ok = false end

			if ok and attrs and mode < 2 then
				for j = 0, vic[from] - 1 do
					if wedge_in(to, vi[from * 4 + j]) < 0 then
						ok = false

						break
					end
				end
			end

			local tx, ty, tz = mx[gid[to]], my[gid[to]], mz[gid[to]]
			fx, fy, fz = mx[gid[from]], my[gid[from]], mz[gid[from]]

			if ok then
				for i = 0, count_from - 1 do
					local t = scratch[i]
					local a, b, c = ta[t], tb[t], tc[t]

					if a ~= to and b ~= to and c ~= to then
						local p0, p1, p2 = gid[a], gid[b], gid[c]
						local ax, ay, az = mx[p0], my[p0], mz[p0]
						local bx, by, bz = mx[p1], my[p1], mz[p1]
						local cx, cy, cz = mx[p2], my[p2], mz[p2]
						local nx0 = (by - ay) * (cz - az) - (bz - az) * (cy - ay)
						local ny0 = (bz - az) * (cx - ax) - (bx - ax) * (cz - az)
						local nz0 = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

						if a == from then
							ax, ay, az = tx, ty, tz
						elseif b == from then
							bx, by, bz = tx, ty, tz
						else
							cx, cy, cz = tx, ty, tz
						end

						local nx1 = (by - ay) * (cz - az) - (bz - az) * (cy - ay)
						local ny1 = (bz - az) * (cx - ax) - (bx - ax) * (cz - az)
						local nz1 = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
						local l0 = sqrt(nx0 * nx0 + ny0 * ny0 + nz0 * nz0)
						local l1 = sqrt(nx1 * nx1 + ny1 * ny1 + nz1 * nz1)

						if l1 < 1e-12 * max(l0, 1e-30) or nx0 * nx1 + ny0 * ny1 + nz0 * nz1 < 0.2 * l0 * l1 then
							ok = false

							break
						end
					end
				end
			end

			local new_dev, new_u, new_n, new_b = 0, 0, 0, 0

			if ok then
				pe_d2, pe_from = math.huge, from

				for j = 0, 3 do
					bd[j] = math.huge
					bok[j] = 0
				end

				for i = 0, count_to - 1 do
					local t = scratch2[i]

					if ta[t] ~= from and tb[t] ~= from and tc[t] ~= from then
						consider(ta[t], tb[t], tc[t], tisl[t])
					end
				end

				for i = 0, count_from - 1 do
					local t = scratch[i]
					local a, b, c = ta[t], tb[t], tc[t]

					if a ~= to and b ~= to and c ~= to then
						if a == from then a = to elseif b == from then b = to else c = to end

						consider(a, b, c, tisl[t])
					end
				end

				if pe_d2 == math.huge then
					local dx, dy, dz = tx - fx, ty - fy, tz - fz
					pe_d2 = dx * dx + dy * dy + dz * dz
				end

				new_dev = dev[from] + sqrt(pe_d2)

				if attrs then
					local worst_uv, worst_n, worst_b = 0, 0, 0

					for j = 0, vic[from] - 1 do
						local w = vw[from * 4 + j]

						if bok[j] == 1 and w >= 0 then
							local du, dv = wu[w] - bu[j], wv[w] - bv[j]
							local nx, ny, nz = bnx[j], bny[j], bnz[j]
							local nl = sqrt(nx * nx + ny * ny + nz * nz)

							if nl > 1e-9 then nx, ny, nz = nx / nl, ny / nl, nz / nl end

							local dnx, dny, dnz = wnx[w] - nx, wny[w] - ny, wnz[w] - nz
							worst_uv = max(worst_uv, sqrt(du * du + dv * dv))
							worst_n = max(worst_n, sqrt(dnx * dnx + dny * dny + dnz * dnz))

							if wbend then
								for k = 0, BEND_VALUES - 1 do
									worst_b = max(worst_b, abs(wbend[w * BEND_VALUES + k] - bb[j * BEND_VALUES + k]))
								end
							end
						end
					end

					new_u, new_n, new_b = udev[from] + worst_uv, ndev[from] + worst_n, bdev[from] + worst_b

					if mode < 2 and (new_u > uv_tol or new_n > normal_tol or new_b > BEND_TOL) then
						ok = false
						attr_rejected = attr_rejected + 1
					end
				end
			end

			if ok then
				if attrs and vic[from] > 1 then seam_collapses = seam_collapses + 1 end

				for i = 0, count_from - 1 do
					local t = scratch[i]

					if ta[t] == to or tb[t] == to or tc[t] == to then
						talive[t] = 0
						tri_count = tri_count - 1
					else
						if ta[t] == from then
							ta[t] = to
						elseif tb[t] == from then
							tb[t] = to
						else
							tc[t] = to
						end

						assert(slots < SLOTS, "slots full")
						slot_tri[slots] = t
						slot_next[slots] = vhead[to]
						vhead[to] = slots
						slots = slots + 1
					end
				end

				for c = 0, 9 do
					q[to * 10 + c] = q[to * 10 + c] + q[from * 10 + c]
				end

				qw[to] = qw[to] + qw[from]
				valive[from] = 0
				ver[to] = ver[to] + 1
				collapses = collapses + 1

				if new_dev > dev[to] then dev[to] = new_dev end

				if new_u > udev[to] then udev[to] = new_u end

				if new_n > ndev[to] then ndev[to] = new_n end

				if new_b > bdev[to] then bdev[to] = new_b end

				stamp = stamp + 1
				local count = gather(to, scratch)
				local list = {}

				for i = 0, count - 1 do
					list[#list + 1] = scratch[i]
				end

				for _, t in ipairs(list) do
					for k = 0, 2 do
						local v = k == 0 and ta[t] or (k == 1 and tb[t] or tc[t])

						if v ~= to and mark3[v] ~= stamp then
							mark3[v] = stamp
							push_edge(to, v)
						end
					end
				end
			else
				rejected = rejected + 1
			end
		end
	end

	local out, out_isl = {}, {}

	for t = 0, nt - 1 do
		if talive[t] == 1 then
			out[#out + 1] = gid[ta[t]]
			out[#out + 1] = gid[tb[t]]
			out[#out + 1] = gid[tc[t]]
			out_isl[#out_isl + 1] = tisl[t]
		end
	end

	err_max = 0

	for l = 0, nv - 1 do
		if valive[l] == 1 then
			err_max = max(err_max, dev[l])
			local g = gid[l]

			if dev[l] > vdev_new[g] then vdev_new[g] = dev[l] end

			if udev[l] > vuv_new[g] then vuv_new[g] = udev[l] end

			if ndev[l] > vnd_new[g] then vnd_new[g] = ndev[l] end

			if bdev[l] > vbd_new[g] then vbd_new[g] = bdev[l] end
		end

		local_of[gid[l]] = -1
		mark1[l], mark2[l], mark3[l] = 0, 0, 0
	end

	stats.collapses = stats.collapses + collapses
	stats.rejected = stats.rejected + rejected
	stats.attr_rejected = (stats.attr_rejected or 0) + attr_rejected
	stats.seam_collapses = (stats.seam_collapses or 0) + seam_collapses
	local result = ffi.new("uint32_t[?]", #out)
	local result_isl = ffi.new("uint32_t[?]", #out_isl)

	for i = 1, #out do
		result[i - 1] = out[i]
	end

	for i = 1, #out_isl do
		result_isl[i - 1] = out_isl[i]
	end

	return result, result_isl, #out / 3, err_max
end

local function union_sphere(spheres)
	table.sort(spheres, function(a, b)
		return a[4] > b[4]
	end)

	local cx, cy, cz, r = spheres[1][1], spheres[1][2], spheres[1][3], spheres[1][4]

	for pass = 1, 2 do
		for i = 1, #spheres do
			local s = spheres[i]
			local dx, dy, dz = s[1] - cx, s[2] - cy, s[3] - cz
			local d = sqrt(dx * dx + dy * dy + dz * dz)

			if d + s[4] > r then
				local new_r = (d + s[4] + r) / 2
				local t = d > 0 and (new_r - r) / d or 0
				cx, cy, cz, r = cx + dx * t, cy + dy * t, cz + dz * t, new_r
			end
		end
	end

	return {cx, cy, cz, r * (1 + 1e-9) + 1e-12}
end

hierarchy.BoundingSphere = bounding_sphere
hierarchy.KdSplit = kd_split

function hierarchy.Build(mesh)
	local_of = ffi.new("int32_t[?]", mesh.nv)

	for i = 0, mesh.nv - 1 do
		local_of[i] = -1
	end

	vdev, vdev_new = ffi.new("double[?]", mesh.nv), ffi.new("double[?]", mesh.nv)
	vuv, vuv_new = ffi.new("double[?]", mesh.nv), ffi.new("double[?]", mesh.nv)
	vnd, vnd_new = ffi.new("double[?]", mesh.nv), ffi.new("double[?]", mesh.nv)
	vbd, vbd_new = ffi.new("double[?]", mesh.nv), ffi.new("double[?]", mesh.nv)
	vshared, vowner = ffi.new("uint8_t[?]", mesh.nv), ffi.new("int32_t[?]", mesh.nv)
	local vfrozen = ffi.new("uint8_t[?]", mesh.nv)
	local clusters = {}
	local group_list = {}
	local result = {
		mesh = mesh,
		clusters = clusters,
		levels = {},
		time = {},
		group_list = group_list,
	}
	local t0 = clock()
	local current = make_clusters(mesh, mesh.tris, mesh.nt, 0, clusters, mesh.isl)
	result.time.cluster = clock() - t0

	for _, c in ipairs(current) do
		c.sph_self = bounding_sphere(mesh, c.tris, c.n)
	end

	local stats = {collapses = 0, rejected = 0}
	local level = 0
	result.levels[1] = {clusters = #current, tris = mesh.nt}
	local group_time, simplify_time, recluster_time = 0, 0, 0
	local groups = 0
	local stuck_groups, stuck_tris = 0, 0

	while #current > 1 do
		level = level + 1
		local t1 = clock()
		local gx, gy, gz = ffi.new("double[?]", #current),
		ffi.new("double[?]", #current),
		ffi.new("double[?]", #current)
		local ids = ffi.new("int32_t[?]", #current)

		for i, c in ipairs(current) do
			local geo = bounding_sphere(mesh, c.tris, c.n)
			gx[i - 1], gy[i - 1], gz[i - 1] = geo[1], geo[2], geo[3]
			ids[i - 1] = i - 1
		end

		local runs = {}
		kd_split(ids, gx, gy, gz, 0, #current, GROUP_CLUSTERS, runs)
		group_time = group_time + clock() - t1
		local next_level = {}
		local tri_total = 0
		ffi.copy(vshared, vfrozen, mesh.nv)
		ffi.fill(vowner, mesh.nv * 4, 0xFF)

		for r = 1, #runs, 2 do
			for i = runs[r], runs[r + 1] - 1 do
				local c = current[ids[i] + 1]
				local ct = c.tris

				for k = 0, c.n * 3 - 1 do
					local v = ct[k]
					local owner = vowner[v]

					if owner < 0 then
						vowner[v] = r
					elseif owner ~= r then
						vshared[v] = 1
					end
				end
			end
		end

		for r = 1, #runs, 2 do
			local members = {}
			local total = 0

			for i = runs[r], runs[r + 1] - 1 do
				local c = current[ids[i] + 1]
				members[#members + 1] = c
				total = total + c.n
			end

			local flat = ffi.new("uint32_t[?]", total * 3)
			local flat_isl = ffi.new("uint32_t[?]", total)
			local at = 0
			local spheres, child_err = {}, 0

			for _, c in ipairs(members) do
				ffi.copy(flat + at * 3, c.tris, c.n * 3 * 4)

				if c.isl then ffi.copy(flat_isl + at, c.isl, c.n * 4) end

				at = at + c.n
				spheres[#spheres + 1] = c.sph_self
				child_err = max(child_err, c.err_self)
			end

			local t2 = clock()
			local out, out_isl, out_n, local_err

			for mode = 0, 2 do
				out, out_isl, out_n, local_err = simplify(mesh, flat, flat_isl, total, floor(total / 2), stats, mode)

				if out_n <= total * 0.9 then break end
			end

			simplify_time = simplify_time + clock() - t2
			groups = groups + 1
			local stuck = out_n > total * 0.9

			if stuck then
				stuck_groups = stuck_groups + 1
				stuck_tris = stuck_tris + total

				for k = 0, total * 3 - 1 do
					vfrozen[flat[k]] = 1
				end
			end

			spheres[#spheres + 1] = bounding_sphere(mesh, flat, total)
			local sphere = union_sphere(spheres)
			local err = max(local_err * ERROR_SCALE, child_err) + 1e-7
			local group = {members = members, level = level - 1, stuck = stuck, err = err, sphere = sphere}
			group_list[#group_list + 1] = group

			for _, c in ipairs(members) do
				c.group = group
			end

			if not stuck then
				for _, c in ipairs(members) do
					c.err_parent = err
					c.sph_parent = sphere
				end
			end

			local t3 = clock()

			if out_n > 0 and not stuck then
				for _, c in ipairs(make_clusters(mesh, out, out_n, level, clusters, mesh.wlookup and out_isl or nil)) do
					c.err_self = err
					c.sph_self = sphere
					c.gen = group
					next_level[#next_level + 1] = c
					tri_total = tri_total + c.n
				end
			end

			recluster_time = recluster_time + clock() - t3
		end

		result.levels[level + 1] = {clusters = #next_level, tris = tri_total}
		vdev, vdev_new = vdev_new, vdev
		ffi.copy(vdev_new, vdev, mesh.nv * 8)
		vuv, vuv_new = vuv_new, vuv
		ffi.copy(vuv_new, vuv, mesh.nv * 8)
		vnd, vnd_new = vnd_new, vnd
		ffi.copy(vnd_new, vnd, mesh.nv * 8)
		vbd, vbd_new = vbd_new, vbd
		ffi.copy(vbd_new, vbd, mesh.nv * 8)
		current = next_level

		if #next_level == 0 then break end
	end

	result.time.group = group_time
	result.time.simplify = simplify_time
	result.time.recluster = recluster_time
	result.time.total = clock() - t0
	result.groups = groups
	result.stuck_groups, result.stuck_tris = stuck_groups, stuck_tris
	result.stats = stats
	return result
end

function hierarchy.Select(result, cam_x, cam_y, cam_z, k, threshold, out)
	local count, tris = 0, 0

	for _, c in ipairs(result.clusters) do
		local s = c.sph_self
		local dx, dy, dz = s[1] - cam_x, s[2] - cam_y, s[3] - cam_z
		local d = max(sqrt(dx * dx + dy * dy + dz * dz) - s[4], 1e-9)
		local own = c.err_self * k / d
		local draw = own <= threshold

		if draw and c.err_parent < math.huge then
			local p = c.sph_parent
			local px, py, pz = p[1] - cam_x, p[2] - cam_y, p[3] - cam_z
			local pd = max(sqrt(px * px + py * py + pz * pz) - p[4], 1e-9)
			draw = c.err_parent * k / pd > threshold
		end

		if draw then
			count = count + 1
			tris = tris + c.n

			if out then out[count] = c end
		end
	end

	return count, tris
end

return hierarchy
