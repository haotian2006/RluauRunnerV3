--!native
--!optimize 2

local R = require(script.Parent.raster)
local Materials = require(script.Parent.materials)

local NEAR = 0.05
local CYL_SEGMENTS = 24
local SPHERE_RINGS = 12
local SHADOW_SIZE = 1024
local SHADOW_FAR = 300
local MAX_GUI_SIDE = 1024

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

local function cylinderFaces(axis)
	local function v(a, b, c)
		return if axis == "X" then V(a, b, c) elseif axis == "Y" then V(b, a, c) else V(b, c, a)
	end
	local faces, normals = {}, {}
	local capHi, capLo = {}, {}
	for i = 0, CYL_SEGMENTS - 1 do
		local a0 = i / CYL_SEGMENTS * 2 * math.pi
		local a1 = (i + 1) / CYL_SEGMENTS * 2 * math.pi
		local c0, s0, c1, s1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
		table.insert(faces, { v(-1, c0, s0), v(-1, c1, s1), v(1, c1, s1), v(1, c0, s0) })
		normals[#faces] = { v(0, c0, s0), v(0, c1, s1), v(0, c1, s1), v(0, c0, s0) }
		capHi[i + 1] = v(1, c0, s0)
		capLo[CYL_SEGMENTS - i] = v(-1, c0, s0)
	end
	table.insert(faces, capHi)
	table.insert(faces, capLo)
	return faces, normals
end

local CYL_X, CYL_X_N = cylinderFaces("X")
local CYL_Y, CYL_Y_N = cylinderFaces("Y")
local CYL_Z, CYL_Z_N = cylinderFaces("Z")

local SPHERE, SPHERE_N = {}, {}
do
	local function at(ring, seg)
		local th = ring / SPHERE_RINGS * math.pi
		local ph = seg / CYL_SEGMENTS * 2 * math.pi
		return V(math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph))
	end
	for ring = 0, SPHERE_RINGS - 1 do
		for seg = 0, CYL_SEGMENTS - 1 do
			local a, b, c, d = at(ring, seg), at(ring, seg + 1), at(ring + 1, seg + 1), at(ring + 1, seg)
			local face = if ring == 0 then { a, c, d } elseif ring == SPHERE_RINGS - 1 then { a, b, c } else { a, b, c, d }
			table.insert(SPHERE, face)
			SPHERE_N[#SPHERE] = face
		end
	end
end

-- Cone along +Z from a base at -1 to an apex at +1.
local CONE, CONE_N = {}, {}
do
	local base = {}
	for i = 0, CYL_SEGMENTS - 1 do
		local a0 = i / CYL_SEGMENTS * 2 * math.pi
		local a1 = (i + 1) / CYL_SEGMENTS * 2 * math.pi
		local p0, p1 = V(math.cos(a0), math.sin(a0), -1), V(math.cos(a1), math.sin(a1), -1)
		table.insert(CONE, { p0, p1, V(0, 0, 1) })
		local n0, n1 = V(p0.X, p0.Y, 0.5).Unit, V(p1.X, p1.Y, 0.5).Unit
		CONE_N[#CONE] = { n0, n1, (n0 + n1).Unit }
		base[CYL_SEGMENTS - i] = p0
	end
	table.insert(CONE, base)
end

local FACES = { block = BLOCK, wedge = WEDGE, corner = CORNER, cylinder = CYL_X, vcylinder = CYL_Y, zcylinder = CYL_Z, ellipsoid = SPHERE, cone = CONE }
local NORMALS = { cylinder = CYL_X_N, vcylinder = CYL_Y_N, zcylinder = CYL_Z_N, ellipsoid = SPHERE_N, cone = CONE_N }
-- A point strictly inside each shape; flat normals are flipped to point away from it. The
-- wedge's slope passes through the box center, so the center can't be used.
local INSIDE = { wedge = V(0, -0.5, 0.5), corner = V(0.5, -0.5, -0.5) }

-- { specular, shininess, reflectance, Fresnel F0 }; unlisted materials are matte.
local MATERIALS = {
	[Enum.Material.Plastic] = { 0.12, 10, 0, 0.1 },
	[Enum.Material.SmoothPlastic] = { 0.3, 24, 0, 0.12 },
	[Enum.Material.Metal] = { 0.1, 40, 0.7, 0 },
	[Enum.Material.DiamondPlate] = { 0.45, 30, 0.08, 0.15 },
	[Enum.Material.CorrodedMetal] = { 0.25, 20, 0, 0.08 },
	[Enum.Material.Foil] = { 0.8, 60, 0.2, 0.25 },
	[Enum.Material.Glass] = { 0.9, 80, 0.25, 0.2 },
	[Enum.Material.Ice] = { 0.6, 50, 0.1, 0.15 },
	[Enum.Material.Glacier] = { 0.5, 40, 0.05, 0.12 },
	[Enum.Material.Marble] = { 0.35, 30, 0.03, 0.06 },
	[Enum.Material.Granite] = { 0.15, 16, 0, 0.03 },
	[Enum.Material.Concrete] = { 0.05, 8, 0, 0.05 },
	[Enum.Material.Slate] = { 0.1, 12, 0, 0.1 },
}
local MATTE = { 0, 8, 0, 0 }
local METALS = {
	[Enum.Material.Metal] = true,
	[Enum.Material.DiamondPlate] = true,
	[Enum.Material.CorrodedMetal] = true,
	[Enum.Material.Foil] = true,
}
-- Studio's reflectance curve is steep: faint when low, near mirror at 1.
local function reflectMix(r)
	return r * r * 0.6
end

local NORMAL_IDS = {
	[Enum.NormalId.Right] = { V(1, 0, 0), V(0, 1, 0) },
	[Enum.NormalId.Left] = { V(-1, 0, 0), V(0, 1, 0) },
	-- a Top decal's top edge faces +Z (checked against Studio)
	[Enum.NormalId.Top] = { V(0, 1, 0), V(0, 0, 1) },
	[Enum.NormalId.Bottom] = { V(0, -1, 0), V(0, 0, -1) },
	[Enum.NormalId.Back] = { V(0, 0, 1), V(0, 1, 0) },
	[Enum.NormalId.Front] = { V(0, 0, -1), V(0, 1, 0) },
}

local function axisOf(v: Vector3)
	return math.abs(v.X), math.abs(v.Y), math.abs(v.Z)
end

local function shapeOf(part: BasePart)
	local size = part.Size
	local mesh = part:FindFirstChildWhichIsA("DataModelMesh")
	if mesh then
		local scale, offset = mesh.Scale, mesh.Offset
		if mesh:IsA("SpecialMesh") then
			local t = mesh.MeshType
			if t == Enum.MeshType.Sphere then
				local h = size * scale / 2
				if math.abs(h.X - h.Y) < 1e-4 and math.abs(h.Y - h.Z) < 1e-4 then
					return "ball", h, offset
				end
				return "ellipsoid", h, offset
			elseif t == Enum.MeshType.Cylinder then
				local h = size * scale / 2
				local r = math.min(h.Y, h.Z)
				return "cylinder", V(h.X, r, r), offset
			elseif t == Enum.MeshType.Wedge then
				return "wedge", size * scale / 2, offset
			elseif t == Enum.MeshType.Head then
				local h = size * scale / 2
				local r = math.min(h.X, h.Z)
				return "vcylinder", V(r, h.Y, r), offset
			elseif t == Enum.MeshType.FileMesh then
				return "block", size / 2, offset
			end
			return "block", size * scale / 2, offset
		elseif mesh:IsA("CylinderMesh") then
			local h = size * scale / 2
			local r = math.min(h.X, h.Z)
			return "vcylinder", V(r, h.Y, r), offset
		end
		return "block", size * scale / 2, offset
	end
	if part:IsA("WedgePart") then
		return "wedge", size / 2, Vector3.zero
	elseif part:IsA("CornerWedgePart") then
		return "corner", size / 2, Vector3.zero
	elseif part:IsA("Part") then
		local s = part.Shape
		if s == Enum.PartType.Ball then
			return "ball", Vector3.one * (math.min(size.X, size.Y, size.Z) / 2), Vector3.zero
		elseif s == Enum.PartType.Cylinder then
			local r = math.min(size.Y, size.Z) / 2
			return "cylinder", V(size.X / 2, r, r), Vector3.zero
		elseif s == Enum.PartType.Wedge then
			return "wedge", size / 2, Vector3.zero
		elseif s == Enum.PartType.CornerWedge then
			return "corner", size / 2, Vector3.zero
		end
	end
	return "block", size / 2, Vector3.zero
end

local function adorneePart(obj)
	local a = obj.Adornee or obj.Parent
	if a and a:IsA("BasePart") then
		return a
	end
	return nil
end

local function adorneeCFrame(obj)
	local a = obj.Adornee or obj.Parent
	if a == nil then
		return nil, nil
	elseif a:IsA("BasePart") then
		return a.CFrame, a.Size
	elseif a:IsA("Attachment") then
		return a.WorldCFrame, Vector3.zero
	elseif a:IsA("Model") then
		local cf, size = a:GetBoundingBox()
		return cf, size
	end
	return nil, nil
end

--[[
	camera (CFrame), fov (radians)
	background: "sky" | Color3 | nil, backgroundAlpha
	light: { toLight, sunDir, light, ambient, skyAmbient, horizon, zenith, ground, sun, sunCos,
		fog = { start, finish, density, color }?, shadows, softness } (colours as Vector3)
	imageFor(decal), meshTexture(part), renderGui(gui, w, h): Image?
	meshGeometry(part): native.readMeshGeometry result for a MeshPart, or nil to draw its box
	scale: output pixels per GUI pixel (supersampling); materials: false for plain colours
Returns the number of parts drawn.
]]
return function(w, root: Instance, opts)
	local W, H = opts.width, opts.height
	local camCF: CFrame = opts.camera
	local camInv = camCF:Inverse()
	local f = (H / 2) / math.tan(opts.fov / 2)
	local cx, cy = W / 2, H / 2
	local light = opts.light
	local pxScale = opts.scale or 1

	local function camVec(v: Vector3)
		return camInv:VectorToWorldSpace(v)
	end

	local parts, decals, guis, adorns, highlights = {}, {}, {}, {}, {}
	local function visit(d)
		if d:IsA("BasePart") then
			if not d:IsA("Terrain") then
				table.insert(parts, d)
			end
		elseif d:IsA("Decal") then
			table.insert(decals, d)
		elseif d:IsA("SurfaceGui") or d:IsA("BillboardGui") then
			if d.Enabled then
				table.insert(guis, d)
			end
		elseif d:IsA("HandleAdornment") or d:IsA("SelectionBox") then
			if d.Visible then
				table.insert(adorns, d)
			end
		elseif d:IsA("Highlight") then
			if d.Enabled then
				table.insert(highlights, d)
			end
		end
	end
	visit(root)
	for _, d in root:GetDescendants() do
		visit(d)
	end

	local scratchP, scratchN, scratchU = {}, {}, {}
	-- nrm: per-vertex camera-space normals; uv: per-vertex { u, v } or nil.
	local function emitPolygon(n, pos, nrm, uv)
		local cn = 0
		for i = 1, n do
			local j = i % n + 1
			local a, b = pos[i], pos[j]
			local ina, inb = a.Z <= -NEAR, b.Z <= -NEAR
			if ina then
				cn += 1
				scratchP[cn], scratchN[cn] = a, nrm[i]
				scratchU[cn] = if uv then uv[i] else nil
			end
			if ina ~= inb then
				local t = (-NEAR - a.Z) / (b.Z - a.Z)
				cn += 1
				scratchP[cn] = a:Lerp(b, t)
				scratchN[cn] = nrm[i]:Lerp(nrm[j], t)
				if uv then
					local ua, ub = uv[i], uv[j]
					scratchU[cn] = { ua[1] + (ub[1] - ua[1]) * t, ua[2] + (ub[2] - ua[2]) * t }
				else
					scratchU[cn] = nil
				end
			end
		end
		if cn < 3 then
			return
		end
		local sx, sy, iz = table.create(cn), table.create(cn), table.create(cn)
		for i = 1, cn do
			local p = scratchP[i]
			local z = -1 / p.Z
			sx[i], sy[i], iz[i] = cx + p.X * z * f, cy - p.Y * z * f, z
		end
		for i = 3, cn do
			local n0, n1, n2 = scratchN[1], scratchN[i - 1], scratchN[i]
			local u0, u1, u2 = scratchU[1], scratchU[i - 1], scratchU[i]
			w:put(R.TRI, sx[1], sy[1], iz[1], sx[i - 1], sy[i - 1], iz[i - 1], sx[i], sy[i], iz[i],
				n0.X, n0.Y, n0.Z, n1.X, n1.Y, n1.Z, n2.X, n2.Y, n2.Z,
				u0 and u0[1] or 0, u0 and u0[2] or 0, u1 and u1[1] or 0, u1 and u1[2] or 0, u2 and u2[1] or 0, u2 and u2[2] or 0)
		end
	end

	local posBuf, nrmBuf, uvBuf = {}, {}, {}
	-- tile (studs) gives faces texture coordinates along the two axes a face is most across.
	local function emitShape(kind, cf: CFrame, half: Vector3, cull: boolean, tile: number?)
		local faces, normals = FACES[kind], NORMALS[kind]
		local inside = cf * ((INSIDE[kind] or Vector3.zero) * half)
		for fi, face in faces do
			local n = #face
			for i = 1, n do
				posBuf[i] = cf * (face[i] * half)
			end
			local uv = nil
			if tile then
				local la = face[1] * half
				local ln = (face[2] * half - la):Cross(face[3] * half - la)
				local ax, ay, az = math.abs(ln.X), math.abs(ln.Y), math.abs(ln.Z)
				uv = uvBuf
				for i = 1, n do
					local lp = face[i] * half
					local u, v
					if ax >= ay and ax >= az then
						u, v = lp.Z, lp.Y
					elseif ay >= az then
						u, v = lp.X, lp.Z
					else
						u, v = lp.X, lp.Y
					end
					uvBuf[i] = { u / tile, -v / tile }
				end
			end
			local a = posBuf[1]
			local flat = (posBuf[2] - a):Cross(posBuf[3] - a)
			if flat.Magnitude < 1e-12 then
				continue
			end
			flat = flat.Unit
			local centroid = a
			for i = 2, n do
				centroid += posBuf[i]
			end
			centroid /= n
			if flat:Dot(centroid - inside) < 0 then
				flat = -flat
			end
			if cull and flat:Dot(a) >= 0 then
				continue
			end
			local vn = normals and normals[fi]
			for i = 1, n do
				nrmBuf[i] = if vn then cf:VectorToWorldSpace((vn[i] / half).Unit) else flat
			end
			emitPolygon(n, posBuf, nrmBuf, uv)
		end
	end

	local function ballBounds(c: Vector3, radius)
		local dz = -c.Z
		if dz - radius > NEAR then
			local lo, hi, lo2, hi2 = math.huge, -math.huge, math.huge, -math.huge
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local p = c + V(sx, sy, sz) * radius
						local iz = -1 / p.Z
						local x, y = cx + p.X * iz * f, cy - p.Y * iz * f
						lo, hi = math.min(lo, x), math.max(hi, x)
						lo2, hi2 = math.min(lo2, y), math.max(hi2, y)
					end
				end
			end
			return math.max(0, math.floor(lo)), math.min(W - 1, math.ceil(hi)), math.max(0, math.floor(lo2)), math.min(H - 1, math.ceil(hi2))
		end
		return 0, W - 1, 0, H - 1
	end

	local function emitBall(c: Vector3, radius)
		if -c.Z + radius < NEAR then
			return
		end
		local x0, x1, y0, y1 = ballBounds(c, radius)
		w:put(R.BALL, c.X, c.Y, c.Z, radius, x0, x1, y0, y1)
	end

	-- Roblox stretches a mesh's bounds over the part's Size.
	local meshCache = {}
	local function meshOf(part: BasePart)
		if not opts.meshGeometry or not part:IsA("MeshPart") then
			return nil
		end
		local hit = meshCache[part]
		if hit ~= nil then
			return hit or nil
		end
		local geo = opts.meshGeometry(part)
		if not geo or (geo.triangleCount or 0) == 0 then
			meshCache[part] = false
			return nil
		end
		local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, p in geo.positions do
			local v = V(p[1], p[2], p[3])
			lo, hi = lo:Min(v), hi:Max(v)
		end
		local extent = hi - lo
		local size = part.Size
		local scale = V(
			if extent.X > 1e-6 then size.X / extent.X else 1,
			if extent.Y > 1e-6 then size.Y / extent.Y else 1,
			if extent.Z > 1e-6 then size.Z / extent.Z else 1
		)
		local center = (lo + hi) / 2
		local tris = table.create(#geo.triangles)
		for i, t in geo.triangles do
			local pos, nrm, uv = table.create(3), table.create(3), table.create(3)
			for corner = 1, 3 do
				local p = geo.positions[t[corner]]
				pos[corner] = (V(p[1], p[2], p[3]) - center) * scale
				local n = geo.normals and geo.normals[i] and geo.normals[i][corner]
				nrm[corner] = if n then V(n[1], n[2], n[3]) / scale else nil
				local u = geo.uvs and geo.uvs[i] and geo.uvs[i][corner]
				uv[corner] = if u then { u[1], u[2] } else { 0, 0 }
			end
			tris[i] = { pos, nrm, uv }
		end
		meshCache[part] = tris
		return tris
	end

	local meshPos, meshNrm = table.create(3), table.create(3)
	local function emitMesh(tris, cf: CFrame, textured: boolean)
		for _, t in tris do
			local pos, nrm = t[1], t[2]
			local p0, p1, p2 = cf * pos[1], cf * pos[2], cf * pos[3]
			local flat = (p1 - p0):Cross(p2 - p0)
			if flat.Magnitude < 1e-12 or flat:Dot(p0) >= 0 then
				continue
			end
			flat = flat.Unit
			meshPos[1], meshPos[2], meshPos[3] = p0, p1, p2
			for corner = 1, 3 do
				local n = nrm[corner]
				meshNrm[corner] = if n and n.Magnitude > 1e-9 then cf:VectorToWorldSpace(n.Unit) else flat
			end
			emitPolygon(3, meshPos, meshNrm, if textured then t[3] else nil)
		end
	end

	local function emitPartGeometry(part: BasePart, cull, tile: number?, textured: boolean?)
		local tris = meshOf(part)
		if tris then
			emitMesh(tris, camInv * part.CFrame, textured == true)
			return
		end
		local kind, half, offset = shapeOf(part)
		local cf = camInv * part.CFrame * CFrame.new(offset)
		if kind == "ball" then
			emitBall(cf.Position, half.X)
		else
			emitShape(kind, cf, half, cull, tile)
		end
	end

	local function material(r, g, b, a, flags, emissive, spec, shin, refl, fres, tex, wrap)
		w:put(R.MATERIAL, r, g, b, a, flags, emissive or 1, spec or 0, shin or 1, refl or 0, fres or 0, tex or 0, if wrap then 1 else 0)
	end

	-- Returns the material texture's tile size (or nil) and whether the mesh's TextureID is used.
	local function partMaterial(part: BasePart): (number?, boolean?)
		local c = part.Color
		local alpha = 1 - part.Transparency
		local mat = part.Material
		if meshOf(part) and opts.meshTexture then
			local img = opts.meshTexture(part)
			if img then
				local m = MATERIALS[mat] or MATTE
				local id = w:texture(img.imageBuffer, img.Size.X, img.Size.Y)
				material(1, 1, 1, alpha, R.SMOOTH + R.TEXTURED, 1, m[1], m[2], math.max(m[3], reflectMix(part.Reflectance)), m[4], id, true)
				return nil, true
			end
		end
		if mat == Enum.Material.Neon then
			material(c.R, c.G, c.B, alpha, R.UNLIT, 1.15)
			return nil
		elseif mat == Enum.Material.ForceField then
			material(c.R, c.G, c.B, alpha * 0.35, R.UNLIT, 1.2)
			return nil
		end
		local m = MATERIALS[mat] or MATTE
		local kind = shapeOf(part)
		local isMesh = meshOf(part) ~= nil
		local flags = if NORMALS[kind] or kind == "ball" or isMesh then R.SMOOTH else 0
		if METALS[mat] then
			flags += R.METAL
		end
		if mat == Enum.Material.Glass and alpha < 1 then
			flags += R.GLASS
		end
		local tex = if opts.materials ~= false and kind ~= "ball" and not isMesh then Materials.texture(mat) else nil
		if tex then
			local id = w:texture(tex[1], tex[2], tex[2])
			local g = Materials.GAIN
			material(c.R * g, c.G * g, c.B * g, alpha, flags + R.TEXTURED, 1, m[1], m[2], math.max(m[3], reflectMix(part.Reflectance)), m[4], id, true)
			return tex[3]
		end
		material(c.R, c.G, c.B, alpha, flags, 1, m[1], m[2], math.max(m[3], reflectMix(part.Reflectance)), m[4])
		return nil
	end

	local bg = opts.background
	if bg == "sky" then
		local up = camVec(Vector3.yAxis)
		local sun = camVec(light.sunDir)
		w:put(R.SKY, f, cx, cy, up.X, up.Y, up.Z,
			light.horizon.X, light.horizon.Y, light.horizon.Z, light.zenith.X, light.zenith.Y, light.zenith.Z,
			light.ground.X, light.ground.Y, light.ground.Z, sun.X, sun.Y, sun.Z,
			light.sun.X, light.sun.Y, light.sun.Z, light.sunCos, light.horizonOffset or 0, light.groundScale or 4)
	elseif bg then
		w:put(R.FILL, bg.R, bg.G, bg.B, opts.backgroundAlpha or 1)
	end
	w:put(R.CAMERA, f, cx, cy)
	do
		local L, up = camVec(light.toLight), camVec(Vector3.yAxis)
		w:put(R.LIGHT, L.X, L.Y, L.Z, up.X, up.Y, up.Z, light.light.X, light.light.Y, light.light.Z,
			light.ambient.X, light.ambient.Y, light.ambient.Z, light.skyAmbient.X, light.skyAmbient.Y, light.skyAmbient.Z,
			light.bounce.X, light.bounce.Y, light.bounce.Z,
			light.horizon.X, light.horizon.Y, light.horizon.Z, light.zenith.X, light.zenith.Y, light.zenith.Z,
			light.ground.X, light.ground.Y, light.ground.Z, light.envSpecular or 0)
	end
	if light.fog then
		local fog = light.fog
		w:put(R.FOG, fog.start, fog.finish, fog.density, fog.color.X, fog.color.Y, fog.color.Z)
	end

	if light.shadows and #parts > 0 then
		local lz = light.toLight.Unit
		local ref = if math.abs(lz.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
		local lx = ref:Cross(lz).Unit
		local ly = lz:Cross(lx)
		local tanY = math.tan(opts.fov / 2)
		local tanX = tanY * W / H
		local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
		local function addPoint(p: Vector3)
			local x, y = p:Dot(lx), p:Dot(ly)
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
		end
		local far = 0
		for _, part in parts do
			if part.Transparency >= 1 then
				continue
			end
			local cf, half = part.CFrame, part.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local p = camInv * (cf * (half * V(sx, sy, sz)))
						far = math.max(far, -p.Z)
					end
				end
			end
		end
		far = math.min(far, SHADOW_FAR)
		for _, d in { NEAR, far } do
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					addPoint(camCF * V(sx * tanX * d, sy * tanY * d, -d))
				end
			end
		end
		local pMinX, pMaxX, pMinY, pMaxY, top = math.huge, -math.huge, math.huge, -math.huge, -math.huge
		for _, part in parts do
			local cf, half = part.CFrame, part.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local p = cf * (half * V(sx, sy, sz))
						local x, y = p:Dot(lx), p:Dot(ly)
						pMinX, pMaxX = math.min(pMinX, x), math.max(pMaxX, x)
						pMinY, pMaxY = math.min(pMinY, y), math.max(pMaxY, y)
						top = math.max(top, p:Dot(lz))
					end
				end
			end
		end
		minX, maxX = math.max(minX, pMinX), math.min(maxX, pMaxX)
		minY, maxY = math.max(minY, pMinY), math.min(maxY, pMaxY)
		local span = math.max(maxX - minX, maxY - minY, 1)
		if maxX > minX and maxY > minY then
			local S = SHADOW_SIZE
			local scale = S / span
			local rc = camCF - camCF.Position
			local t = camCF.Position
			local ax, ay, az = rc:VectorToObjectSpace(lx), rc:VectorToObjectSpace(ly), rc:VectorToObjectSpace(lz)
			local texel = span / S
			w:put(R.SHADOW_BEGIN, S,
				ax.X * scale, ax.Y * scale, ax.Z * scale, (t:Dot(lx) - minX) * scale,
				ay.X * scale, ay.Y * scale, ay.Z * scale, (t:Dot(ly) - minY) * scale,
				az.X, az.Y, az.Z, t:Dot(lz),
				texel * 2 + 0.05, if light.softness and light.softness > 0.05 then 2 else 1)
			local function toMap(p: Vector3)
				return (p:Dot(lx) - minX) * scale, (p:Dot(ly) - minY) * scale, p:Dot(lz)
			end
			for _, part in parts do
				if not part.CastShadow or part.Transparency >= 1 or part.Material == Enum.Material.ForceField then
					continue
				end
				local tris = meshOf(part)
				if tris then
					local cf = part.CFrame
					for _, t in tris do
						local pos = t[1]
						local x0, y0, z0 = toMap(cf * pos[1])
						local x1, y1, z1 = toMap(cf * pos[2])
						local x2, y2, z2 = toMap(cf * pos[3])
						w:put(R.SHADOW_TRI, x0, y0, z0, x1, y1, z1, x2, y2, z2)
					end
					continue
				end
				local kind, half, offset = shapeOf(part)
				local cf = part.CFrame * CFrame.new(offset)
				if kind == "ball" then
					local x, y, z = toMap(cf.Position)
					w:put(R.SHADOW_BALL, x, y, z, half.X * scale, 1 / scale)
					continue
				end
				for _, face in FACES[kind] do
					local n = #face
					local x0, y0, z0 = toMap(cf * (face[1] * half))
					local x1, y1, z1 = toMap(cf * (face[2] * half))
					for i = 3, n do
						local x2, y2, z2 = toMap(cf * (face[i] * half))
						w:put(R.SHADOW_TRI, x0, y0, z0, x1, y1, z1, x2, y2, z2)
						x1, y1, z1 = x2, y2, z2
					end
				end
			end
			w:put(R.SHADOW_END)
		end
	end

	local drawn = 0
	local function drawPart(part: BasePart)
		local tile, textured = partMaterial(part)
		emitPartGeometry(part, true, tile, textured)
		drawn += 1
	end
	local see = {}
	for _, part in parts do
		local t = part.Transparency
		if t >= 1 then
			continue
		end
		if t > 0 or part.Material == Enum.Material.ForceField then
			table.insert(see, { part, -(camInv * part.CFrame).Position.Z })
		else
			drawPart(part)
		end
	end

	local function faceQuad(part: BasePart, face: Enum.NormalId)
		local info = NORMAL_IDS[face]
		if not info then
			return nil
		end
		local n, up = info[1], info[2]
		local right = up:Cross(n)
		local half = part.Size / 2
		local hn, hr, hu = n * half, right * half, up * half
		local width, height = (right * part.Size).Magnitude, (up * part.Size).Magnitude
		local cf = camInv * part.CFrame
		return {
			cf * (hn - hr - hu), cf * (hn + hr - hu), cf * (hn + hr + hu), cf * (hn - hr + hu),
		}, cf:VectorToWorldSpace(n), width, height
	end

	local function drawFaceImage(part, face, img, tint, alpha, uvs, wrap, flags, emissive)
		local quad, normal = faceQuad(part, face)
		if not quad or normal:Dot(quad[1]) >= 0 then
			return
		end
		local tex = w:texture(img.imageBuffer, img.Size.X, img.Size.Y)
		material(tint.R, tint.G, tint.B, alpha, R.TEXTURED + R.DECAL + (flags or 0), emissive, 0, 1, 0, 0, tex, wrap)
		emitPolygon(4, quad, { normal, normal, normal, normal }, uvs)
	end

	for _, decal in decals do
		local part = decal.Parent
		if not part or not part:IsA("BasePart") or decal.Transparency >= 1 then
			continue
		end
		local img = opts.imageFor and opts.imageFor(decal)
		if not img then
			continue
		end
		local uvs = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } }
		local wrap = false
		if decal:IsA("Texture") then
			local _, _, fw, fh = faceQuad(part, decal.Face)
			if not fw then
				continue
			end
			local su, sv = math.max(decal.StudsPerTileU, 1e-3), math.max(decal.StudsPerTileV, 1e-3)
			local ou, ov = decal.OffsetStudsU / su, decal.OffsetStudsV / sv
			local u1, v1 = fw / su, fh / sv
			uvs = { { -ou, v1 - ov }, { u1 - ou, v1 - ov }, { u1 - ou, -ov }, { -ou, -ov } }
			wrap = true
		end
		drawFaceImage(part, decal.Face, img, decal.Color3, 1 - decal.Transparency, uvs, wrap)
	end

	for _, gui in guis do
		if gui:IsA("SurfaceGui") then
			local part = adorneePart(gui)
			if not part or not opts.renderGui then
				continue
			end
			local _, _, fw, fh = faceQuad(part, gui.Face)
			if not fw then
				continue
			end
			local cw, ch
			if gui.SizingMode == Enum.SurfaceGuiSizingMode.PixelsPerStud then
				cw, ch = fw * gui.PixelsPerStud, fh * gui.PixelsPerStud
			else
				cw, ch = gui.CanvasSize.X, gui.CanvasSize.Y
			end
			local scale = math.min(1, MAX_GUI_SIDE / math.max(cw, ch, 1))
			local img = opts.renderGui(gui, math.max(1, math.floor(cw * scale)), math.max(1, math.floor(ch * scale)), cw, ch)
			if img then
				local lit = gui.LightInfluence > 0.5
				local flags = (if lit then 0 else R.UNLIT) + (if gui.AlwaysOnTop then R.ON_TOP else 0)
				drawFaceImage(part, gui.Face, img, Color3.new(1, 1, 1), 1, { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } }, false, flags, gui.Brightness)
			end
		end
	end

	local onTop = {}
	local function drawAdornment(a)
		local base = adorneeCFrame(a)
		if not base then
			return
		end
		local c = a.Color3
		local alpha = 1 - a.Transparency
		if alpha <= 0 then
			return
		end
		local flags = R.UNLIT + (if a:IsA("HandleAdornment") and a.AlwaysOnTop then R.ON_TOP else 0)
		material(c.R, c.G, c.B, alpha, flags, 1)
		if a:IsA("SelectionBox") then
			local cf, size = adorneeCFrame(a)
			local t = a.LineThickness
			local h = size / 2
			for axis = 1, 3 do
				for s1 = -1, 1, 2 do
					for s2 = -1, 1, 2 do
						local center, edge
						if axis == 1 then
							center, edge = V(0, s1 * h.Y, s2 * h.Z), V(size.X / 2 + t / 2, t / 2, t / 2)
						elseif axis == 2 then
							center, edge = V(s1 * h.X, 0, s2 * h.Z), V(t / 2, size.Y / 2 + t / 2, t / 2)
						else
							center, edge = V(s1 * h.X, s2 * h.Y, 0), V(t / 2, t / 2, size.Z / 2 + t / 2)
						end
						emitShape("block", camInv * cf * CFrame.new(center), edge, true)
					end
				end
			end
			return
		end
		local cf = camInv * base * a.CFrame
		if a:IsA("BoxHandleAdornment") then
			emitShape("block", cf, a.Size / 2, true)
		elseif a:IsA("SphereHandleAdornment") then
			emitBall(cf.Position, a.Radius)
		elseif a:IsA("CylinderHandleAdornment") then
			emitShape("zcylinder", cf, V(a.Radius, a.Radius, a.Height / 2), true)
		elseif a:IsA("ConeHandleAdornment") then
			emitShape("cone", cf, V(a.Radius, a.Radius, a.Height / 2), true)
		elseif a:IsA("LineHandleAdornment") then
			-- Thickness is in pixels, so size the box from the line's middle depth.
			local mid = cf * V(0, 0, -a.Length / 2)
			local studs = math.max(a.Thickness, 1) * pxScale * math.max(-mid.Z, NEAR) / f
			emitShape("block", cf * CFrame.new(0, 0, -a.Length / 2), V(studs / 2, studs / 2, a.Length / 2), false)
		end
	end
	for _, a in adorns do
		if a:IsA("HandleAdornment") and a.AlwaysOnTop then
			table.insert(onTop, a)
		else
			drawAdornment(a)
		end
	end

	table.sort(see, function(a, b)
		return a[2] > b[2]
	end)
	for _, entry in see do
		drawPart(entry[1])
	end

	for _, h in highlights do
		local target = h.Adornee or h.Parent
		if not target then
			continue
		end
		local hp = {}
		if target:IsA("BasePart") then
			table.insert(hp, target)
		end
		for _, d in target:GetDescendants() do
			if d:IsA("BasePart") and not d:IsA("Terrain") then
				table.insert(hp, d)
			end
		end
		local fc, oc = h.FillColor, h.OutlineColor
		w:put(R.HIGHLIGHT_BEGIN, if h.DepthMode == Enum.HighlightDepthMode.AlwaysOnTop then 1 else 0,
			fc.R, fc.G, fc.B, 1 - h.FillTransparency, oc.R, oc.G, oc.B, 1 - h.OutlineTransparency, 2 * pxScale)
		for _, part in hp do
			if part.Transparency < 1 then
				emitPartGeometry(part, true)
			end
		end
		w:put(R.HIGHLIGHT_END)
	end

	for _, a in onTop do
		drawAdornment(a)
	end
	for _, gui in guis do
		if not gui:IsA("BillboardGui") or not opts.renderGui then
			continue
		end
		local base, size = adorneeCFrame(gui)
		if not base then
			continue
		end
		local right, up = camCF.RightVector, camCF.UpVector
		local ext = gui.ExtentsOffset
		local worldPos = base.Position + gui.StudsOffsetWorldSpace
			+ right * (gui.StudsOffset.X + ext.X * size.X / 2)
			+ up * (gui.StudsOffset.Y + ext.Y * size.Y / 2)
			- camCF.LookVector * gui.StudsOffset.Z
		local p = camInv * worldPos
		if -p.Z < NEAR then
			continue
		end
		local dist = -p.Z
		if gui.MaxDistance > 0 and gui.MaxDistance < math.huge and (worldPos - camCF.Position).Magnitude > gui.MaxDistance then
			continue
		end
		local studsToPx = f / dist
		local s = gui.Size
		local gw = s.X.Scale * studsToPx / pxScale + s.X.Offset
		local gh = s.Y.Scale * studsToPx / pxScale + s.Y.Offset
		if gw < 1 or gh < 1 then
			continue
		end
		local pw, ph = gw * pxScale, gh * pxScale
		local scale = math.min(1, MAX_GUI_SIDE / math.max(gw, gh))
		local img = opts.renderGui(gui, math.max(1, math.floor(gw * scale)), math.max(1, math.floor(gh * scale)), gw, gh)
		if not img then
			continue
		end
		local sx, sy = cx + p.X / dist * f, cy - p.Y / dist * f
		local x0, y0 = sx - pw / 2, sy - ph / 2
		local x1, y1 = x0 + pw, y0 + ph
		local iz = 1 / dist
		local tex = w:texture(img.imageBuffer, img.Size.X, img.Size.Y)
		local flags = R.TEXTURED + R.UNLIT + (if gui.AlwaysOnTop then R.ON_TOP else R.DECAL)
		material(1, 1, 1, 1, flags, 1, 0, 1, 0, 0, tex, false)
		local n = { 0, 0, 1 }
		w:put(R.TRI, x0, y0, iz, x1, y0, iz, x1, y1, iz, n[1], n[2], n[3], n[1], n[2], n[3], n[1], n[2], n[3], 0, 0, 1, 0, 1, 1)
		w:put(R.TRI, x0, y0, iz, x1, y1, iz, x0, y1, iz, n[1], n[2], n[3], n[1], n[2], n[3], n[1], n[2], n[3], 0, 0, 1, 1, 0, 1)
	end

	return drawn
end
