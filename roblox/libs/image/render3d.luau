--!native
--!optimize 2
-- Projects BaseParts into an RGBA buffer with a depth buffer. Blocks, wedges, corner
-- wedges and cylinders are triangulated; balls are traced per pixel so they stay round.

local NEAR = 0.05
local CYL_SEGMENTS = 24
local YIELD_AFTER = 0.05

local V = Vector3.new

-- Unit-space faces ([-1, 1] per axis), each a convex polygon.
local BLOCK = {
	{ V(1, -1, -1), V(1, 1, -1), V(1, 1, 1), V(1, -1, 1) },
	{ V(-1, -1, -1), V(-1, -1, 1), V(-1, 1, 1), V(-1, 1, -1) },
	{ V(-1, 1, -1), V(-1, 1, 1), V(1, 1, 1), V(1, 1, -1) },
	{ V(-1, -1, -1), V(1, -1, -1), V(1, -1, 1), V(-1, -1, 1) },
	{ V(-1, -1, 1), V(1, -1, 1), V(1, 1, 1), V(-1, 1, 1) },
	{ V(-1, -1, -1), V(-1, 1, -1), V(1, 1, -1), V(1, -1, -1) },
}
-- Top rises from the front (-Z) to the back (+Z).
local WEDGE = {
	{ V(-1, -1, -1), V(1, -1, -1), V(1, -1, 1), V(-1, -1, 1) },
	{ V(-1, -1, 1), V(1, -1, 1), V(1, 1, 1), V(-1, 1, 1) },
	{ V(-1, -1, -1), V(1, -1, -1), V(1, 1, 1), V(-1, 1, 1) },
	{ V(1, -1, -1), V(1, -1, 1), V(1, 1, 1) },
	{ V(-1, -1, -1), V(-1, -1, 1), V(-1, 1, 1) },
}
-- Peak above the (+X, -Z) corner.
local CORNER = {
	{ V(-1, -1, -1), V(1, -1, -1), V(1, -1, 1), V(-1, -1, 1) },
	{ V(1, -1, -1), V(1, -1, 1), V(1, 1, -1) },
	{ V(-1, -1, -1), V(1, -1, -1), V(1, 1, -1) },
	{ V(-1, -1, -1), V(-1, -1, 1), V(1, 1, -1) },
	{ V(-1, -1, 1), V(1, -1, 1), V(1, 1, -1) },
}
-- Axis along X; side faces carry per-vertex normals for smooth shading.
local CYLINDER, CYLINDER_NORMALS = {}, {}
do
	local ring = {}
	for i = 0, CYL_SEGMENTS - 1 do
		local a = i / CYL_SEGMENTS * 2 * math.pi
		ring[i + 1] = V(0, math.cos(a), math.sin(a))
	end
	local capL, capR = {}, {}
	for i = 1, CYL_SEGMENTS do
		local r, n = ring[i], ring[i % CYL_SEGMENTS + 1]
		table.insert(CYLINDER, { r - V(1, 0, 0), n - V(1, 0, 0), n + V(1, 0, 0), r + V(1, 0, 0) })
		CYLINDER_NORMALS[#CYLINDER] = { r, n, n, r }
		capR[i] = r + V(1, 0, 0)
		capL[CYL_SEGMENTS - i + 1] = r - V(1, 0, 0)
	end
	table.insert(CYLINDER, capR)
	table.insert(CYLINDER, capL)
end

local function clamp01(x)
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

local function pack(r, g, b, a)
	return bit32.bor(
		math.floor(clamp01(r) * 255 + 0.5),
		bit32.lshift(math.floor(clamp01(g) * 255 + 0.5), 8),
		bit32.lshift(math.floor(clamp01(b) * 255 + 0.5), 16),
		bit32.lshift(math.floor(clamp01(a) * 255 + 0.5), 24)
	)
end

local function shapeOf(part: BasePart)
	if part:IsA("WedgePart") then
		return "wedge"
	elseif part:IsA("CornerWedgePart") then
		return "corner"
	elseif part:IsA("Part") then
		local s = part.Shape
		if s == Enum.PartType.Ball then
			return "ball"
		elseif s == Enum.PartType.Cylinder then
			return "cylinder"
		elseif s == Enum.PartType.Wedge then
			return "wedge"
		elseif s == Enum.PartType.CornerWedge then
			return "corner"
		end
	end
	return "block"
end

local FACES = { block = BLOCK, wedge = WEDGE, corner = CORNER, cylinder = CYLINDER }
-- A point strictly inside each shape; normals are flipped to point away from it. The
-- wedge's slope passes through the box center, so the center can't be used.
local INSIDE = { block = V(0, 0, 0), wedge = V(0, -0.5, 0.5), corner = V(0.5, -0.5, -0.5), cylinder = V(0, 0, 0) }

return function(parts: { BasePart }, opts)
	local W, H = opts.width, opts.height
	local camCF: CFrame = opts.camera
	local camInv = camCF:Inverse()
	local f = (H / 2) / math.tan(opts.fov / 2)
	local cx, cy = W / 2, H / 2
	local toLight: Vector3 = opts.toLight
	local amb: Vector3, lightCol: Vector3 = opts.ambient, opts.lightColor
	local skyAmb = opts.skyAmbient or 0

	local color = buffer.create(W * H * 4)
	local depth = buffer.create(W * H * 4)

	-- background
	local bg = opts.background
	if bg == "sky" then
		local horizon, zenith, ground = V(0.80, 0.88, 0.97), V(0.42, 0.62, 0.92), V(0.50, 0.53, 0.57)
		local rx, ry = camCF.RightVector.Y, camCF.UpVector.Y
		local fy = -camCF.LookVector.Y
		for y = 0, H - 1 do
			local ny = (cy - (y + 0.5)) / f
			for x = 0, W - 1 do
				local nx = (x + 0.5 - cx) / f
				local dy = (rx * nx + ry * ny - fy) / math.sqrt(nx * nx + ny * ny + 1)
				local c = if dy >= 0 then horizon:Lerp(zenith, dy ^ 0.6) else horizon:Lerp(ground, math.min(1, -dy * 4))
				buffer.writeu32(color, (y * W + x) * 4, pack(c.X, c.Y, c.Z, 1))
			end
		end
	elseif bg then
		local packed = pack(bg.R, bg.G, bg.B, opts.backgroundAlpha or 1)
		for i = 0, W * H - 1 do
			buffer.writeu32(color, i * 4, packed)
		end
	end

	local lastYield = os.clock()
	local function maybeYield()
		if os.clock() - lastYield > YIELD_AFTER then
			task.wait()
			lastYield = os.clock()
		end
	end

	-- Shared by the triangle rasterizer: the face's colour/alpha and shading terms.
	local baseR, baseG, baseB, alpha = 0, 0, 0, 1
	local ambR, ambG, ambB = 0, 0, 0
	local litR, litG, litB = 0, 0, 0
	local flatPacked: number? = nil

	local function plot(idx, z, d)
		local zi = idx * 4
		if z <= buffer.readf32(depth, zi) then
			return
		end
		local packed = flatPacked
		local r, g, b
		if packed == nil or alpha < 1 then
			if packed == nil then
				r = baseR * (ambR + litR * d)
				g = baseG * (ambG + litG * d)
				b = baseB * (ambB + litB * d)
			else
				r = bit32.band(packed, 255) / 255
				g = bit32.band(bit32.rshift(packed, 8), 255) / 255
				b = bit32.band(bit32.rshift(packed, 16), 255) / 255
			end
		end
		if alpha >= 1 then
			buffer.writef32(depth, zi, z)
			buffer.writeu32(color, zi, packed or pack(r, g, b, 1))
			return
		end
		-- transparent: "over" onto what's there, no depth write
		local dst = buffer.readu32(color, zi)
		local da = bit32.rshift(dst, 24) / 255
		local oa = alpha + da * (1 - alpha)
		if oa <= 0 then
			return
		end
		local k = da * (1 - alpha)
		buffer.writeu32(color, zi, pack(
			(r * alpha + (bit32.band(dst, 255) / 255) * k) / oa,
			(g * alpha + (bit32.band(bit32.rshift(dst, 8), 255) / 255) * k) / oa,
			(b * alpha + (bit32.band(bit32.rshift(dst, 16), 255) / 255) * k) / oa,
			oa
		))
	end

	-- vertices: screen x, y, 1/depth, diffuse term
	local function rasterTri(x0, y0, z0, d0, x1, y1, z1, d1, x2, y2, z2, d2)
		local area = (x2 - x1) * (y0 - y1) - (y2 - y1) * (x0 - x1)
		if area == 0 then
			return
		end
		local minX = math.max(0, math.floor(math.min(x0, x1, x2)))
		local maxX = math.min(W - 1, math.ceil(math.max(x0, x1, x2)))
		local minY = math.max(0, math.floor(math.min(y0, y1, y2)))
		local maxY = math.min(H - 1, math.ceil(math.max(y0, y1, y2)))
		if minX > maxX or minY > maxY then
			return
		end
		local inv = 1 / area
		local a0x, a1x, a2x = -(y2 - y1) * inv, -(y0 - y2) * inv, -(y1 - y0) * inv
		local a0y, a1y, a2y = (x2 - x1) * inv, (x0 - x2) * inv, (x1 - x0) * inv
		local px, py = minX + 0.5, minY + 0.5
		local r0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) * inv
		local r1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) * inv
		local r2 = ((x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)) * inv
		local smooth = flatPacked == nil
		local q0, q1, q2 = d0 * z0, d1 * z1, d2 * z2
		for y = minY, maxY do
			local w0, w1, w2 = r0, r1, r2
			local idx = y * W + minX
			for _ = minX, maxX do
				if w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6 then
					local z = w0 * z0 + w1 * z1 + w2 * z2
					local d = 0
					if smooth then
						d = (w0 * q0 + w1 * q1 + w2 * q2) / z
					end
					plot(idx, z, d)
				end
				w0 += a0x
				w1 += a1x
				w2 += a2x
				idx += 1
			end
			r0 += a0y
			r1 += a1y
			r2 += a2y
		end
	end

	-- Clips a camera-space polygon to the near plane, projects and fans it.
	local px, pd = {}, {}
	local function drawPolygon(n, pos, dif)
		local cn = 0
		for i = 1, n do
			local a, b = pos[i], pos[i % n + 1]
			local da, db = dif[i], dif[i % n + 1]
			local ina, inb = a.Z <= -NEAR, b.Z <= -NEAR
			if ina then
				cn += 1
				px[cn], pd[cn] = a, da
			end
			if ina ~= inb then
				local t = (-NEAR - a.Z) / (b.Z - a.Z)
				cn += 1
				px[cn], pd[cn] = a:Lerp(b, t), da + (db - da) * t
			end
		end
		if cn < 3 then
			return
		end
		local p0 = px[1]
		local iz0 = -1 / p0.Z
		local sx0, sy0 = cx + p0.X * iz0 * f, cy - p0.Y * iz0 * f
		local p1 = px[2]
		local iz1 = -1 / p1.Z
		local sx1, sy1 = cx + p1.X * iz1 * f, cy - p1.Y * iz1 * f
		for i = 3, cn do
			local p2 = px[i]
			local iz2 = -1 / p2.Z
			local sx2, sy2 = cx + p2.X * iz2 * f, cy - p2.Y * iz2 * f
			rasterTri(sx0, sy0, iz0, pd[1], sx1, sy1, iz1, pd[i - 1], sx2, sy2, iz2, pd[i])
			sx1, sy1, iz1 = sx2, sy2, iz2
		end
	end

	local function setMaterial(part: BasePart)
		local c = part.Color
		baseR, baseG, baseB = c.R, c.G, c.B
		alpha = 1 - part.Transparency
		if part.Material == Enum.Material.Neon then
			ambR, ambG, ambB, litR, litG, litB = 1.15, 1.15, 1.15, 0, 0, 0
		else
			ambR, ambG, ambB = amb.X, amb.Y, amb.Z
			litR, litG, litB = lightCol.X, lightCol.Y, lightCol.Z
		end
	end

	local pos, dif = {}, {}
	local drawn = 0

	local function drawFaces(part: BasePart, cf: CFrame, half: Vector3, faces, inside: Vector3, normals)
		local center = cf * (inside * half)
		local partRot = part.CFrame
		for fi, face in faces do
			local n = #face
			for i = 1, n do
				pos[i] = cf * (face[i] * half)
			end
			local a = pos[1]
			local nrm = (pos[2] - a):Cross(pos[3] - a)
			if nrm.Magnitude < 1e-12 then
				continue
			end
			nrm = nrm.Unit
			local centroid = a
			for i = 2, n do
				centroid += pos[i]
			end
			centroid /= n
			if nrm:Dot(centroid - center) < 0 then
				nrm = -nrm
			end
			if nrm:Dot(a) >= 0 then
				continue
			end
			local worldN = camCF:VectorToWorldSpace(nrm)
			local sky = skyAmb * (worldN.Y * 0.5 + 0.5)
			local fr, fg, fb = ambR, ambG, ambB
			ambR, ambG, ambB = fr + sky, fg + sky, fb + sky
			local vn = normals and normals[fi]
			if vn then
				flatPacked = nil
				for i = 1, n do
					dif[i] = math.max(0, partRot:VectorToWorldSpace(vn[i]):Dot(toLight))
				end
			else
				local d = math.max(0, worldN:Dot(toLight))
				flatPacked = pack(baseR * (ambR + litR * d), baseG * (ambG + litG * d), baseB * (ambB + litB * d), 1)
				for i = 1, n do
					dif[i] = d
				end
			end
			drawPolygon(n, pos, dif)
			ambR, ambG, ambB = fr, fg, fb
			drawn += 1
		end
	end

	local function drawBall(part: BasePart, cf: CFrame, radius: number)
		local c = cf.Position
		local dz = -c.Z
		if dz + radius < NEAR then
			return
		end
		local minX, maxX, minY, maxY = 0, W - 1, 0, H - 1
		if dz - radius > NEAR then
			local lo, hi = math.huge, -math.huge
			local lo2, hi2 = math.huge, -math.huge
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local p = c + V(sx, sy, sz) * radius
						local iz = -1 / p.Z
						local x, y = cx + p.X * iz * f, cy - p.Y * iz * f
						lo, hi = math.min(lo, x), math.max(hi, x)
						lo2, hi2 = math.min(lo2, y), math.max(hi2, y)
					end
				end
			end
			minX, maxX = math.max(0, math.floor(lo)), math.min(W - 1, math.ceil(hi))
			minY, maxY = math.max(0, math.floor(lo2)), math.min(H - 1, math.ceil(hi2))
		end
		local cc = c:Dot(c) - radius * radius
		local skyBase = skyAmb
		local ar, ag, ab = ambR, ambG, ambB
		flatPacked = nil
		for y = minY, maxY do
			local dyN = -(y + 0.5 - cy) / f
			for x = minX, maxX do
				local dxN = (x + 0.5 - cx) / f
				local a = dxN * dxN + dyN * dyN + 1
				local b = dxN * c.X + dyN * c.Y - c.Z
				local disc = b * b - a * cc
				if disc < 0 then
					continue
				end
				local t = (b - math.sqrt(disc)) / a
				if t < NEAR then
					continue
				end
				local hit = V(dxN * t, dyN * t, -t)
				local worldN = camCF:VectorToWorldSpace((hit - c) / radius)
				local sky = skyBase * (worldN.Y * 0.5 + 0.5)
				ambR, ambG, ambB = ar + sky, ag + sky, ab + sky
				plot(y * W + x, 1 / t, math.max(0, worldN:Dot(toLight)))
			end
		end
		ambR, ambG, ambB = ar, ag, ab
		drawn += 1
	end

	local function drawPart(part: BasePart)
		setMaterial(part)
		local cf = camInv * part.CFrame
		local size = part.Size
		local shape = shapeOf(part)
		if shape == "ball" then
			drawBall(part, cf, math.min(size.X, size.Y, size.Z) / 2)
		elseif shape == "cylinder" then
			local r = math.min(size.Y, size.Z) / 2
			drawFaces(part, cf, V(size.X / 2, r, r), CYLINDER, INSIDE.cylinder, CYLINDER_NORMALS)
		else
			drawFaces(part, cf, size / 2, FACES[shape], INSIDE[shape])
		end
		maybeYield()
	end

	local see = {}
	for _, part in parts do
		local t = part.Transparency
		if t >= 1 then
			continue
		end
		if t > 0 then
			table.insert(see, { part, -(camInv * part.CFrame).Position.Z })
		else
			drawPart(part)
		end
	end
	table.sort(see, function(a, b)
		return a[2] > b[2]
	end)
	for _, entry in see do
		drawPart(entry[1])
	end

	return color, drawn
end
