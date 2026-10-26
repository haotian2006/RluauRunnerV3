--!native
--!optimize 2
-- Must give the same pixels as luau_native's rasterize (luau-bot-headless
-- mods/luau_native/image/image_raster.cpp); keep the math in step.
-- A command list is a buffer of f64s: an op code, then its arguments.
--   CLIP x0 y0 x1 y1                      clip rect for 2D shapes (x1, y1 exclusive)
--   LAYER                                 starts a CanvasGroup layer
--   COMPOSITE alpha r g b                 draws the layer onto the one below, tinted
--   SHAPE x y w h rot cos sin lx0 ly0 lx1 ly1 <cover> <paint> <gradient>
--     cover: FULL | RRECT x0 y0 x1 y1 tl tr bl br | RING x0 y0 x1 y1 tl tr bl br outer inner join
--            | GLYPH tex gx gy gw gh qx qy k kx distScale extra shear baseY
--            | SHADOW x0 y0 x1 y1 tl tr bl br blur
--            | PATH half n x1 y1 ... xn yn
--     paint: SOLID r g b a | IMAGE tex rx ry rw rh mode dx0 dy0 dw dh tileW tileH sl st sr sb ss
--            pixelated r g b a
--     gradient: 0 | 1 cos sin offX offY w h nc (t r g b)*nc nt (t v)*nt
--   FILL r g b a                          3D background colour
--   SKY f cx cy up(3) horizon(3) zenith(3) ground(3) sunDir(3) sun(3) sunCos offset groundScale
--   CAMERA f cx cy                      projection: pixel (x, y) at depth d is ((x+.5-cx)/f*d, (cy-y-.5)/f*d, -d)
--   LIGHT toLight(3) up(3) light(3) ambient(3) skyAmbient(3) bounce(3) horizon(3) zenith(3) ground(3) envSpecular
--   FOG start end density r g b
--   MATERIAL r g b alpha flags emissive specular shininess reflectance fresnel tex wrap
--   TRI (x y iz)*3 (nx ny nz)*3 (u v)*3   screen x, y and 1/depth; camera-space normals
--   BALL cx cy cz radius minX maxX minY maxY
--   SHADOW_BEGIN size m(12) bias pcf      m maps camera space to shadow-map x, y, height
--   SHADOW_TRI (x y z)*3 | SHADOW_BALL x y z r k | SHADOW_END   (r in map texels, k studs per texel)
--   HIGHLIGHT_BEGIN mode fill(3) fillAlpha outline(3) outlineAlpha outlineRadius | HIGHLIGHT_END
-- Camera space looks down -Z; textures are { buf, width, height, channels } by id (1-based).

local R = {}

R.CLIP, R.LAYER, R.COMPOSITE, R.SHAPE = 1, 2, 3, 4
R.FILL, R.SKY, R.LIGHT, R.FOG, R.MATERIAL, R.TRI, R.BALL = 20, 21, 22, 23, 24, 25, 26
R.SHADOW_BEGIN, R.SHADOW_TRI, R.SHADOW_BALL, R.SHADOW_END = 27, 28, 29, 30
R.HIGHLIGHT_BEGIN, R.HIGHLIGHT_END, R.CAMERA = 31, 32, 33

R.FULL, R.RRECT, R.RING, R.GLYPH, R.SHADOW, R.PATH = 0, 1, 2, 3, 4, 5
R.SOLID, R.IMAGE = 0, 1
R.JOIN_ROUND, R.JOIN_MITER, R.JOIN_BEVEL = 0, 1, 2
R.MODE_STRETCH, R.MODE_TILE, R.MODE_SLICE = 0, 1, 2

R.SMOOTH, R.UNLIT, R.TEXTURED, R.NO_SHADOW, R.ON_TOP, R.DECAL, R.METAL, R.GLASS = 1, 2, 4, 8, 16, 32, 64, 128

local NEAR = 0.05
local SQRT1_2 = math.sqrt(0.5)


local readf64, writef64 = buffer.readf64, buffer.writef64
local readu32, writeu32 = buffer.readu32, buffer.writeu32
local readu8, writeu8 = buffer.readu8, buffer.writeu8
local readf32, writef32 = buffer.readf32, buffer.writef32
local floor, ceil, sqrt, min, max, abs = math.floor, math.ceil, math.sqrt, math.min, math.max, math.abs
local bor, band, lshift, rshift = bit32.bor, bit32.band, bit32.lshift, bit32.rshift

local Writer = {}
Writer.__index = Writer

function R.writer()
	return setmetatable({ buf = buffer.create(8192), n = 0, textures = {}, ids = {} }, Writer)
end

function Writer:reserve(count)
	local need = (self.n + count) * 8
	local len = buffer.len(self.buf)
	if need > len then
		local grown = buffer.create(math.max(need, len * 2))
		buffer.copy(grown, 0, self.buf, 0, self.n * 8)
		self.buf = grown
	end
end

function Writer:put(...)
	local count = select("#", ...)
	self:reserve(count)
	local buf, n = self.buf, self.n
	for i = 1, count do
		writef64(buf, (n + i - 1) * 8, (select(i, ...)))
	end
	self.n = n + count
end

function Writer:putList(list)
	self:reserve(#list)
	local buf, n = self.buf, self.n
	for i, v in list do
		writef64(buf, (n + i - 1) * 8, v)
	end
	self.n = n + #list
end

function Writer:texture(pixels: buffer, width: number, height: number, channels: number?): number
	local id = self.ids[pixels]
	if id then
		return id
	end
	table.insert(self.textures, { pixels, width, height, channels or 4 })
	id = #self.textures
	self.ids[pixels] = id
	return id
end

local function clamp01(x)
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

local function tone(x)
	if x <= 0.6 then
		return x
	end
	return 0.6 + 0.4 * (1 - math.exp(-(x - 0.6) / 0.4))
end

local function pack(r, g, b, a)
	return bor(
		floor(clamp01(r) * 255 + 0.5),
		lshift(floor(clamp01(g) * 255 + 0.5), 8),
		lshift(floor(clamp01(b) * 255 + 0.5), 16),
		lshift(floor(clamp01(a) * 255 + 0.5), 24)
	)
end

local function blend(color, i, r, g, b, a)
	if a <= 0.002 then
		return
	end
	if a >= 0.998 then
		writeu32(color, i, bor(
			floor(clamp01(r) * 255 + 0.5),
			lshift(floor(clamp01(g) * 255 + 0.5), 8),
			lshift(floor(clamp01(b) * 255 + 0.5), 16),
			0xFF000000
		))
		return
	end
	local dst = readu32(color, i)
	local da = rshift(dst, 24) / 255
	local oa = a + da * (1 - a)
	local k = da * (1 - a)
	writeu32(color, i, bor(
		floor(clamp01((r * a + (band(dst, 255) / 255) * k) / oa) * 255 + 0.5),
		lshift(floor(clamp01((g * a + (band(rshift(dst, 8), 255) / 255) * k) / oa) * 255 + 0.5), 8),
		lshift(floor(clamp01((b * a + (band(rshift(dst, 16), 255) / 255) * k) / oa) * 255 + 0.5), 16),
		lshift(floor(clamp01(oa) * 255 + 0.5), 24)
	))
end

-- Signed distance to a rounded rect over [x0, x1] x [y0, y1], negative inside. The corner radius
-- is the one for the quadrant of (u, v); join picks the outside metric of square corners.
local function rrDist(u, v, x0, y0, x1, y1, tl, tr, bl, br, join)
	local hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
	local du, dv = u - x0 - hw, v - y0 - hh
	local r = if du < 0 then (if dv < 0 then tl else bl) else (if dv < 0 then tr else br)
	local qx = abs(du) - (hw - r)
	local qy = abs(dv) - (hh - r)
	local ox, oy = max(qx, 0), max(qy, 0)
	local outside
	if r > 0 or join == 0 then
		outside = sqrt(ox * ox + oy * oy)
	elseif join == 1 then
		outside = max(ox, oy)
	else
		outside = max(max(ox, oy), (ox + oy) * SQRT1_2)
	end
	return outside + min(max(qx, qy), 0) - r
end

local function seqColor(keys, n, t)
	if t <= keys[1] then
		return keys[2], keys[3], keys[4]
	end
	for i = 2, n do
		local b = (i - 1) * 4 + 1
		if t <= keys[b] then
			local a = b - 4
			local span = keys[b] - keys[a]
			local f = if span > 0 then (t - keys[a]) / span else 0
			return keys[a + 1] + (keys[b + 1] - keys[a + 1]) * f,
				keys[a + 2] + (keys[b + 2] - keys[a + 2]) * f,
				keys[a + 3] + (keys[b + 3] - keys[a + 3]) * f
		end
	end
	local last = (n - 1) * 4 + 1
	return keys[last + 1], keys[last + 2], keys[last + 3]
end

local function seqNumber(keys, n, t)
	if t <= keys[1] then
		return keys[2]
	end
	for i = 2, n do
		local b = (i - 1) * 2 + 1
		if t <= keys[b] then
			local a = b - 2
			local span = keys[b] - keys[a]
			return keys[a + 1] + (keys[b + 1] - keys[a + 1]) * (if span > 0 then (t - keys[a]) / span else 0)
		end
	end
	return keys[(n - 1) * 2 + 2]
end

local function sampleRGBA(tex, x, y, wrap)
	local pixels, w, h = tex[1], tex[2], tex[3]
	x -= 0.5
	y -= 0.5
	if wrap then
		x = x % w
		y = y % h
	else
		x = if x < 0 then 0 elseif x > w - 1 then w - 1 else x
		y = if y < 0 then 0 elseif y > h - 1 then h - 1 else y
	end
	local ix, iy = floor(x), floor(y)
	local fx, fy = x - ix, y - iy
	local ix1 = if wrap then (ix + 1) % w else min(ix + 1, w - 1)
	local iy1 = if wrap then (iy + 1) % h else min(iy + 1, h - 1)
	local p00 = readu32(pixels, (iy * w + ix) * 4)
	local p10 = readu32(pixels, (iy * w + ix1) * 4)
	local p01 = readu32(pixels, (iy1 * w + ix) * 4)
	local p11 = readu32(pixels, (iy1 * w + ix1) * 4)
	local out = table.create(4)
	for c = 0, 3 do
		local shift = c * 8
		local a = band(rshift(p00, shift), 255)
		local b = band(rshift(p10, shift), 255)
		local cc = band(rshift(p01, shift), 255)
		local d = band(rshift(p11, shift), 255)
		local t0 = a + (b - a) * fx
		out[c + 1] = (t0 + ((cc + (d - cc) * fx) - t0) * fy) / 255
	end
	return out[1], out[2], out[3], out[4]
end

function R.run(cmds: buffer, count: number, width: number, height: number, color: buffer, textures, yield)
	local W, H = width, height
	local p = 0
	local function rd()
		local v = readf64(cmds, p * 8)
		p += 1
		return v
	end

	local clip = { 0, 0, W, H }
	local target = color
	local layers = {}

	local depth: buffer? = nil
	local lx, ly, lz, ux, uy, uz = 0, 0, 1, 0, 1, 0
	local lightR, lightG, lightB = 0, 0, 0
	local ambR, ambG, ambB, skyR, skyG, skyB = 1, 1, 1, 0, 0, 0
	local bounceR, bounceG, bounceB, envSpecular = 0, 0, 0, 0
	local horR, horG, horB, zenR, zenG, zenB, grnR, grnG, grnB = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local fogStart, fogEnd, fogDensity, fogR, fogG, fogB = 0, 0, 0, 0, 0, 0
	local fogOn = false
	local f3, cx3, cy3 = 1, W / 2, H / 2
	local baseR, baseG, baseB, alpha, flags, emissive, spec, shininess, reflect, fresnel, texture, wrap =
		1, 1, 1, 1, 0, 1, 0, 1, 0, 0, nil, false
	local shadowMap: buffer? = nil
	local shadowSize, shadowBias, shadowPcf = 0, 0, 0
	local sm = table.create(12, 0)
	local shadowBuild: buffer? = nil
	local mask: buffer? = nil
	local maskMode = 0
	local maskX0, maskY0, maskX1, maskY1 = W, H, -1, -1

	local function ensureDepth()
		if not depth then
			depth = buffer.create(W * H * 4)
		end
		return depth :: buffer
	end

	local function readGradient()
		if rd() == 0 then
			return nil
		end
		local g = { c = rd(), s = rd(), ox = rd(), oy = rd(), w = rd(), h = rd() }
		local nc = rd()
		local ck = table.create(nc * 4)
		for i = 1, nc * 4 do
			ck[i] = rd()
		end
		local nt = rd()
		local tk = table.create(nt * 2)
		for i = 1, nt * 2 do
			tk[i] = rd()
		end
		g.nc, g.ck, g.nt, g.tk = nc, ck, nt, tk
		return g
	end

	local function shape()
		local gx, gy, gw, gh, rot, gcos, gsin = rd(), rd(), rd(), rd(), rd(), rd(), rd()
		local lx0, ly0, lx1, ly1 = rd(), rd(), rd(), rd()

		local cover
		local kind = rd()
		if kind == R.FULL then
			cover = function()
				return 1
			end
		elseif kind == R.RRECT then
			local x0, y0, x1, y1, tl, tr, bl, br = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
			cover = function(u, v)
				return clamp01(0.5 - rrDist(u, v, x0, y0, x1, y1, tl, tr, bl, br, 0))
			end
		elseif kind == R.RING then
			local x0, y0, x1, y1, tl, tr, bl, br = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
			local outer, inner, join = rd(), rd(), rd()
			cover = function(u, v)
				local d = rrDist(u, v, x0, y0, x1, y1, tl, tr, bl, br, join)
				return clamp01(0.5 - (d - outer)) - clamp01(0.5 - (d + inner))
			end
		elseif kind == R.GLYPH then
			local tex = textures[rd()]
			local pixels, atlasW = tex[1], tex[2]
			local gx0, gy0, gw0, gh0, qx, qy, k, kx, distScale, extra =
				rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
			local shear, baseY = rd(), rd()
			cover = function(u, v)
				local ax = (u - shear * (baseY - v) - qx) / kx - 0.5
				local ay = (v - qy) / k - 0.5
				if ax < 0 then ax = 0 elseif ax > gw0 - 1 then ax = gw0 - 1 end
				if ay < 0 then ay = 0 elseif ay > gh0 - 1 then ay = gh0 - 1 end
				local ix, iy = floor(ax), floor(ay)
				local tx, ty = ax - ix, ay - iy
				local ix1, iy1 = min(ix + 1, gw0 - 1), min(iy + 1, gh0 - 1)
				local row0, row1 = (gy0 + iy) * atlasW + gx0, (gy0 + iy1) * atlasW + gx0
				local s00 = readu8(pixels, row0 + ix)
				local s10 = readu8(pixels, row0 + ix1)
				local s01 = readu8(pixels, row1 + ix)
				local s11 = readu8(pixels, row1 + ix1)
				local top0 = s00 + (s10 - s00) * tx
				local val = top0 + ((s01 + (s11 - s01) * tx) - top0) * ty
				return clamp01((val - 127.5) * distScale + 0.5 + extra)
			end
		elseif kind == R.SHADOW then
			local x0, y0, x1, y1, tl, tr, bl, br, blur = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
			cover = function(u, v)
				local d = rrDist(u, v, x0, y0, x1, y1, tl, tr, bl, br, 0)
				if blur <= 0 then
					return clamp01(0.5 - d)
				end
				local t = clamp01(0.5 - d / (2 * blur))
				return t * t * (3 - 2 * t)
			end
		elseif kind == R.PATH then
			local half, n = rd(), rd()
			local pts = table.create(n * 2)
			for i = 1, n * 2 do
				pts[i] = rd()
			end
			cover = function(u, v)
				local best = math.huge
				for i = 1, n - 1 do
					local ax, ay = pts[i * 2 - 1], pts[i * 2]
					local bx, by = pts[i * 2 + 1], pts[i * 2 + 2]
					local dx, dy = bx - ax, by - ay
					local len2 = dx * dx + dy * dy
					local t = if len2 > 0 then clamp01(((u - ax) * dx + (v - ay) * dy) / len2) else 0
					local ex, ey = u - (ax + dx * t), v - (ay + dy * t)
					local d2 = ex * ex + ey * ey
					if d2 < best then
						best = d2
					end
				end
				return clamp01(0.5 - (sqrt(best) - half))
			end
		else
			error("raster: unknown cover " .. kind)
		end

		local paint
		local pkind = rd()
		if pkind == R.SOLID then
			local r, g, b, a = rd(), rd(), rd(), rd()
			paint = function()
				return r, g, b, a
			end
		elseif pkind == R.IMAGE then
			local tex = textures[rd()]
			local src, iw, ih = tex[1], tex[2], tex[3]
			local rx, ry, rw, rh, mode = rd(), rd(), rd(), rd(), rd()
			local dx0, dy0, dw, dh, tileW, tileH = rd(), rd(), rd(), rd(), rd(), rd()
			local sl, st, sr, sb, ss, pixelated = rd(), rd(), rd(), rd(), rd(), rd() ~= 0
			local tr, tg, tb, alphaI = rd(), rd(), rd(), rd()
			local slice = mode == R.MODE_SLICE
			local function axis(pp, d0, dlen, len, lo, hi)
				if slice then
					local a, b = lo * ss, hi * ss
					if pp < a then
						return pp / ss
					elseif pp > dlen - b then
						return len - (dlen - pp) / ss
					end
					local mid = dlen - a - b
					return lo + (if mid > 0 then (pp - a) / mid else 0) * (len - lo - hi)
				end
				return (pp - d0) / dlen * len
			end
			paint = function(u, v)
				local sx, sy
				if mode == R.MODE_TILE then
					sx, sy = (u % tileW) / tileW * rw, (v % tileH) / tileH * rh
				else
					sx, sy = axis(u, dx0, dw, rw, sl, sr), axis(v, dy0, dh, rh, st, sb)
				end
				local ix, iy, fx, fy
				if pixelated then
					ix = floor(math.clamp(sx, 0, rw - 1e-3)) + rx
					iy = floor(math.clamp(sy, 0, rh - 1e-3)) + ry
					fx, fy = 0, 0
				else
					sx = math.clamp(sx - 0.5, 0, rw - 1) + rx
					sy = math.clamp(sy - 0.5, 0, rh - 1) + ry
					ix, iy = floor(sx), floor(sy)
					fx, fy = sx - ix, sy - iy
				end
				local ix1, iy1 = min(ix + 1, iw - 1), min(iy + 1, ih - 1)
				local p00 = readu32(src, (iy * iw + ix) * 4)
				local p10 = readu32(src, (iy * iw + ix1) * 4)
				local p01 = readu32(src, (iy1 * iw + ix) * 4)
				local p11 = readu32(src, (iy1 * iw + ix1) * 4)
				local function ch(shift)
					local a = band(rshift(p00, shift), 255)
					local b = band(rshift(p10, shift), 255)
					local c = band(rshift(p01, shift), 255)
					local d = band(rshift(p11, shift), 255)
					local t0 = a + (b - a) * fx
					return (t0 + ((c + (d - c) * fx) - t0) * fy) / 255
				end
				return ch(0) * tr, ch(8) * tg, ch(16) * tb, ch(24) * alphaI
			end
		else
			error("raster: unknown paint " .. pkind)
		end

		local grad = readGradient()
		local work = target
		local function shade(u, v)
			local cov = cover(u, v)
			if cov <= 0 then
				return 0, 0, 0, 0
			end
			local r, g, b, a = paint(u, v)
			a *= cov
			if grad then
				local x, y = u / grad.w - 0.5 - grad.ox, v / grad.h - 0.5 - grad.oy
				local t = math.clamp(x * grad.c + y * grad.s + 0.5, 0, 1)
				local cr, cg, cb = seqColor(grad.ck, grad.nc, t)
				r, g, b, a = r * cr, g * cg, b * cb, a * (1 - seqNumber(grad.tk, grad.nt, t))
			end
			return r, g, b, a
		end

		if rot == 0 then
			local sx0 = max(clip[1], floor(gx + lx0))
			local sy0 = max(clip[2], floor(gy + ly0))
			local sx1 = min(clip[3], ceil(gx + lx1)) - 1
			local sy1 = min(clip[4], ceil(gy + ly1)) - 1
			for sy = sy0, sy1 do
				local v = sy + 0.5 - gy
				if v < ly0 or v > ly1 then
					continue
				end
				local row = sy * W
				for sx = sx0, sx1 do
					local u = sx + 0.5 - gx
					if u >= lx0 and u <= lx1 then
						local r, g, b, a = shade(u, v)
						if a > 0 then
							blend(work, (row + sx) * 4, r, g, b, a)
						end
					end
				end
			end
			return
		end
		local cx, cy = gx + gw / 2, gy + gh / 2
		local hw, hh = gw / 2, gh / 2
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		for corner = 1, 4 do
			local px = if corner == 1 or corner == 3 then lx0 else lx1
			local py = if corner <= 2 then ly0 else ly1
			local dx, dy = px - hw, py - hh
			local x, y = cx + dx * gcos - dy * gsin, cy + dx * gsin + dy * gcos
			minX, maxX = min(minX, x), max(maxX, x)
			minY, maxY = min(minY, y), max(maxY, y)
		end
		local sx0, sy0 = max(clip[1], floor(minX)), max(clip[2], floor(minY))
		local sx1, sy1 = min(clip[3], ceil(maxX)) - 1, min(clip[4], ceil(maxY)) - 1
		for sy = sy0, sy1 do
			local dy = sy + 0.5 - cy
			local row = sy * W
			for sx = sx0, sx1 do
				local dx = sx + 0.5 - cx
				local u = dx * gcos + dy * gsin + hw
				local v = -dx * gsin + dy * gcos + hh
				if u >= lx0 and u <= lx1 and v >= ly0 and v <= ly1 then
					local r, g, b, a = shade(u, v)
					if a > 0 then
						blend(work, (row + sx) * 4, r, g, b, a)
					end
				end
			end
		end
	end

	local function composite(groupAlpha, tr, tg, tb)
		local layer = target
		target = table.remove(layers) :: buffer
		for i = 0, W * H - 1 do
			local s = readu32(layer, i * 4)
			local a = rshift(s, 24) / 255
			if a > 0 then
				blend(target, i * 4, band(s, 255) / 255 * tr, band(rshift(s, 8), 255) / 255 * tg,
					band(rshift(s, 16), 255) / 255 * tb, a * groupAlpha)
			end
		end
	end

	local function sunlight(x, y, z)
		local m = sm
		local sx = m[1] * x + m[2] * y + m[3] * z + m[4]
		local sy = m[5] * x + m[6] * y + m[7] * z + m[8]
		local sz = m[9] * x + m[10] * y + m[11] * z + m[12]
		local map = shadowMap :: buffer
		local S = shadowSize
		local ix, iy = floor(sx), floor(sy)
		local lit, total = 0, 0
		for oy = -shadowPcf, shadowPcf do
			for ox = -shadowPcf, shadowPcf do
				local px, py = ix + ox, iy + oy
				total += 1
				if px < 0 or py < 0 or px >= S or py >= S or sz + shadowBias >= readf32(map, (py * S + px) * 4) then
					lit += 1
				end
			end
		end
		return lit / total
	end

	local function skyColor(dx, dy, dz)
		local t = dx * ux + dy * uy + dz * uz
		if t >= 0 then
			return horR + (zenR - horR) * t, horG + (zenG - horG) * t, horB + (zenB - horB) * t
		end
		local k = min(1, -t * 4)
		return horR + (grnR - horR) * k, horG + (grnG - horG) * k, horB + (grnB - horB) * k
	end

	local function shadeSurface(px, py, pz, nx, ny, nz, r, g, b)
		if band(flags, R.UNLIT) ~= 0 then
			return r * emissive, g * emissive, b * emissive
		end
		local diff = nx * lx + ny * ly + nz * lz
		if diff < 0 then
			diff = 0
		end
		local sun = 1
		if diff > 0 and shadowMap and band(flags, R.NO_SHADOW) == 0 then
			sun = sunlight(px, py, pz)
		end
		local hemi = (nx * ux + ny * uy + nz * uz) * 0.5 + 0.5
		local low = 1 - hemi
		local outR = r * (ambR + skyR * hemi + bounceR * low + lightR * diff * sun)
		local outG = g * (ambG + skyG * hemi + bounceG * low + lightG * diff * sun)
		local outB = b * (ambB + skyB * hemi + bounceB * low + lightB * diff * sun)
		if spec > 0 and diff > 0 then
			local vl = sqrt(px * px + py * py + pz * pz)
			local hx, hy, hz = lx - px / vl, ly - py / vl, lz - pz / vl
			local hl = sqrt(hx * hx + hy * hy + hz * hz)
			if hl > 0 then
				local nh = (nx * hx + ny * hy + nz * hz) / hl
				if nh > 0 then
					local s = spec * nh ^ shininess * sun
					outR += lightR * s
					outG += lightG * s
					outB += lightB * s
				end
			end
		end
		if reflect > 0 or fresnel > 0 then
			local vl = sqrt(px * px + py * py + pz * pz)
			local vx, vy, vz = px / vl, py / vl, pz / vl
			local vn = vx * nx + vy * ny + vz * nz
			local d = 2 * vn
			local sr, sg, sb = skyColor(vx - d * nx, vy - d * ny, vz - d * nz)
			if band(flags, R.METAL) ~= 0 then
				sr, sg, sb = sr * r, sg * g, sb * b
			end
			if reflect > 0 then
				outR = outR * (1 - reflect) + sr * reflect
				outG = outG * (1 - reflect) + sg * reflect
				outB = outB * (1 - reflect) + sb * reflect
			end
			if fresnel > 0 then
				local c = 1 + vn
				if c < 0 then
					c = 0
				elseif c > 1 then
					c = 1
				end
				local c2 = c * c
				local k = (fresnel + (1 - fresnel) * c2 * c2 * c) * envSpecular
				outR += sr * k
				outG += sg * k
				outB += sb * k
			end
		end
		outR, outG, outB = tone(outR), tone(outG), tone(outB)
		if fogOn then
			local dist = sqrt(px * px + py * py + pz * pz)
			local fl = if fogEnd > fogStart then clamp01((dist - fogStart) / (fogEnd - fogStart)) else 0
			local fe = if fogDensity > 0 then 1 - math.exp(-fogDensity * dist) else 0
			local fk = max(fl, fe)
			outR += (fogR - outR) * fk
			outG += (fogG - outG) * fk
			outB += (fogB - outB) * fk
		end
		return outR, outG, outB
	end

	-- Transparent samples blend without writing depth.
	local function put(idx, z, r, g, b, a)
		local zi = idx * 4
		if a >= 1 then
			if band(flags, R.ON_TOP + R.DECAL) == 0 then
				writef32(depth :: buffer, zi, z)
			end
			writeu32(target, zi, pack(r, g, b, 1))
			return
		end
		if band(flags, R.GLASS) ~= 0 then
			-- Glass filters what is behind by its colour (full tint by Transparency 0.5).
			local dst = readu32(target, zi)
			if rshift(dst, 24) == 255 then
				local t = min(1, 2 * a)
				local s = a * 0.25
				writeu32(target, zi, pack(
					(band(dst, 255) / 255) * (1 - t + t * baseR) + r * s,
					(band(rshift(dst, 8), 255) / 255) * (1 - t + t * baseG) + g * s,
					(band(rshift(dst, 16), 255) / 255) * (1 - t + t * baseB) + b * s,
					1
				))
				return
			end
		end
		blend(target, zi, r, g, b, a)
	end

	-- While a highlight is open, marks the mask instead of drawing.
	local function visible(idx, z)
		local d = depth :: buffer
		local zi = idx * 4
		if mask then
			if maskMode == 1 or z >= readf32(d, zi) * (1 - 1e-4) then
				return true
			end
			return false
		end
		if band(flags, R.ON_TOP) ~= 0 then
			return true
		end
		if band(flags, R.DECAL) ~= 0 then
			return z >= readf32(d, zi) * (1 - 1e-4)
		end
		return z > readf32(d, zi)
	end

	local function markMask(idx, x, y)
		writeu8(mask :: buffer, idx, 1)
		if x < maskX0 then maskX0 = x end
		if x > maskX1 then maskX1 = x end
		if y < maskY0 then maskY0 = y end
		if y > maskY1 then maskY1 = y end
	end

	local function triangle()
		local x0, y0, z0, x1, y1, z1, x2, y2, z2 = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
		local n0x, n0y, n0z, n1x, n1y, n1z, n2x, n2y, n2z = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
		local u0, v0, u1, v1, u2, v2 = rd(), rd(), rd(), rd(), rd(), rd()
		local area = (x2 - x1) * (y0 - y1) - (y2 - y1) * (x0 - x1)
		if area == 0 then
			return
		end
		local minX = max(0, floor(min(x0, x1, x2)))
		local maxX = min(W - 1, ceil(max(x0, x1, x2)))
		local minY = max(0, floor(min(y0, y1, y2)))
		local maxY = min(H - 1, ceil(max(y0, y1, y2)))
		if minX > maxX or minY > maxY then
			return
		end
		local inv = 1 / area
		local a0x, a1x, a2x = -(y2 - y1) * inv, -(y0 - y2) * inv, -(y1 - y0) * inv
		local a0y, a1y, a2y = (x2 - x1) * inv, (x0 - x2) * inv, (x1 - x0) * inv
		local sx, sy = minX + 0.5, minY + 0.5
		local r0 = ((x2 - x1) * (sy - y1) - (y2 - y1) * (sx - x1)) * inv
		local r1 = ((x0 - x2) * (sy - y2) - (y0 - y2) * (sx - x2)) * inv
		local r2 = ((x1 - x0) * (sy - y0) - (y1 - y0) * (sx - x0)) * inv

		local smooth = band(flags, R.SMOOTH) ~= 0
		local textured = band(flags, R.TEXTURED) ~= 0 and texture ~= nil
		local constant = not smooth and not textured and spec == 0 and reflect == 0 and fresnel == 0 and not fogOn
			and (shadowMap == nil or band(flags, R.NO_SHADOW + R.UNLIT) ~= 0)
		local flatR, flatG, flatB = 0, 0, 0
		if constant then
			flatR, flatG, flatB = shadeSurface(0, 0, -1, n0x, n0y, n0z, baseR, baseG, baseB)
		end
		local flatPacked = pack(flatR, flatG, flatB, 1)
		local opaque = alpha >= 1

		for y = minY, maxY do
			local w0, w1, w2 = r0, r1, r2
			local idx = y * W + minX
			for x = minX, maxX do
				if w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6 then
					local z = w0 * z0 + w1 * z1 + w2 * z2
					if z > 0 and visible(idx, z) then
						if mask then
							markMask(idx, x, y)
						elseif constant and opaque then
							if band(flags, R.ON_TOP + R.DECAL) == 0 then
								writef32(depth :: buffer, idx * 4, z)
							end
							writeu32(target, idx * 4, flatPacked)
						else
							local d = 1 / z
							local px, py, pz = (x + 0.5 - cx3) / f3 * d, (cy3 - (y + 0.5)) / f3 * d, -d
							local nx, ny, nz = n0x, n0y, n0z
							if smooth then
								local q0, q1, q2 = w0 * z0 / z, w1 * z1 / z, w2 * z2 / z
								nx = q0 * n0x + q1 * n1x + q2 * n2x
								ny = q0 * n0y + q1 * n1y + q2 * n2y
								nz = q0 * n0z + q1 * n1z + q2 * n2z
								local nl = sqrt(nx * nx + ny * ny + nz * nz)
								if nl > 0 then
									nx, ny, nz = nx / nl, ny / nl, nz / nl
								end
							end
							local r, g, b, a = baseR, baseG, baseB, alpha
							if textured then
								local q0, q1, q2 = w0 * z0 / z, w1 * z1 / z, w2 * z2 / z
								local tex = texture :: any
								local tr, tg, tb, ta = sampleRGBA(tex, (q0 * u0 + q1 * u1 + q2 * u2) * tex[2],
									(q0 * v0 + q1 * v1 + q2 * v2) * tex[3], wrap)
								r, g, b, a = r * tr, g * tg, b * tb, a * ta
							end
							if constant then
								r, g, b = flatR, flatG, flatB
							else
								r, g, b = shadeSurface(px, py, pz, nx, ny, nz, r, g, b)
							end
							if a > 0 then
								put(idx, z, r, g, b, a)
							end
						end
					end
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

	local function ball()
		local bx, by, bz, radius = rd(), rd(), rd(), rd()
		local minX, maxX, minY, maxY = rd(), rd(), rd(), rd()
		local cc = bx * bx + by * by + bz * bz - radius * radius
		for y = minY, maxY do
			local dyN = -(y + 0.5 - cy3) / f3
			for x = minX, maxX do
				local dxN = (x + 0.5 - cx3) / f3
				local a = dxN * dxN + dyN * dyN + 1
				local b = dxN * bx + dyN * by - bz
				local disc = b * b - a * cc
				if disc < 0 then
					continue
				end
				local t = (b - sqrt(disc)) / a
				if t < NEAR then
					continue
				end
				local idx = y * W + x
				local z = 1 / t
				if not visible(idx, z) then
					continue
				end
				if mask then
					markMask(idx, x, y)
					continue
				end
				local px, py, pz = dxN * t, dyN * t, -t
				local r, g, b = shadeSurface(px, py, pz, (px - bx) / radius, (py - by) / radius, (pz - bz) / radius,
					baseR, baseG, baseB)
				put(idx, z, r, g, b, alpha)
			end
		end
	end

	local function sky()
		local f, scx, scy = rd(), rd(), rd()
		local upx, upy, upz = rd(), rd(), rd()
		local hr, hg, hb, zr, zg, zb, gr, gg, gb = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
		local sdx, sdy, sdz, sr, sg, sb, sunCos = rd(), rd(), rd(), rd(), rd(), rd(), rd()
		local offset, groundScale = rd(), rd()
		for y = 0, H - 1 do
			local ny = (scy - (y + 0.5)) / f
			for x = 0, W - 1 do
				local nx = (x + 0.5 - scx) / f
				local len = sqrt(nx * nx + ny * ny + 1)
				local dy = (upx * nx + upy * ny - upz) / len + offset
				local r, g, b
				if dy >= 0 then
					local t = dy ^ 0.75
					r, g, b = hr + (zr - hr) * t, hg + (zg - hg) * t, hb + (zb - hb) * t
				else
					local t = min(1, -dy * groundScale)
					t = t * t * (3 - 2 * t)
					r, g, b = hr + (gr - hr) * t, hg + (gg - hg) * t, hb + (gb - hb) * t
				end
				local sd = (sdx * nx + sdy * ny - sdz) / len
				if sd > 0.9 and sunCos < 1 then
					local glow = sd ^ 256 * 0.45
					r, g, b = r + sr * glow, g + sg * glow, b + sb * glow
					if sd > sunCos then
						local k = clamp01((sd - sunCos) / (1 - sunCos) * 4)
						r, g, b = r + (sr - r) * k, g + (sg - g) * k, b + (sb - b) * k
					end
				end
				writeu32(target, (y * W + x) * 4, pack(r, g, b, 1))
			end
		end
	end

	local function shadowTri(map, S)
		local x0, y0, z0, x1, y1, z1, x2, y2, z2 = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
		local area = (x2 - x1) * (y0 - y1) - (y2 - y1) * (x0 - x1)
		if area == 0 then
			return
		end
		local minX = max(0, floor(min(x0, x1, x2)))
		local maxX = min(S - 1, ceil(max(x0, x1, x2)))
		local minY = max(0, floor(min(y0, y1, y2)))
		local maxY = min(S - 1, ceil(max(y0, y1, y2)))
		if minX > maxX or minY > maxY then
			return
		end
		local inv = 1 / area
		local a0x, a1x, a2x = -(y2 - y1) * inv, -(y0 - y2) * inv, -(y1 - y0) * inv
		local a0y, a1y, a2y = (x2 - x1) * inv, (x0 - x2) * inv, (x1 - x0) * inv
		local sx, sy = minX + 0.5, minY + 0.5
		local r0 = ((x2 - x1) * (sy - y1) - (y2 - y1) * (sx - x1)) * inv
		local r1 = ((x0 - x2) * (sy - y2) - (y0 - y2) * (sx - x2)) * inv
		local r2 = ((x1 - x0) * (sy - y0) - (y1 - y0) * (sx - x0)) * inv
		for y = minY, maxY do
			local w0, w1, w2 = r0, r1, r2
			local idx = (y * S + minX) * 4
			for _ = minX, maxX do
				if w0 >= -1e-6 and w1 >= -1e-6 and w2 >= -1e-6 then
					local z = w0 * z0 + w1 * z1 + w2 * z2
					if z > readf32(map, idx) then
						writef32(map, idx, z)
					end
				end
				w0 += a0x
				w1 += a1x
				w2 += a2x
				idx += 4
			end
			r0 += a0y
			r1 += a1y
			r2 += a2y
		end
	end

	local function shadowBall(map, S)
		local bx, by, bz, r, k = rd(), rd(), rd(), rd(), rd()
		local minX, maxX = max(0, floor(bx - r)), min(S - 1, ceil(bx + r))
		local minY, maxY = max(0, floor(by - r)), min(S - 1, ceil(by + r))
		for y = minY, maxY do
			local dy = y + 0.5 - by
			for x = minX, maxX do
				local dx = x + 0.5 - bx
				local d2 = r * r - dx * dx - dy * dy
				if d2 >= 0 then
					local z = bz + sqrt(d2) * k
					local i = (y * S + x) * 4
					if z > readf32(map, i) then
						writef32(map, i, z)
					end
				end
			end
		end
	end

	local function finishHighlight(fr, fg, fb, fa, orr, og, ob, oa, radius)
		local m = mask :: buffer
		mask = nil
		if maskX1 < 0 then
			return
		end
		local OUTLINE_RADIUS = floor(radius)
		local R2 = radius * radius + 0.5
		local x0, y0 = max(0, maskX0 - OUTLINE_RADIUS), max(0, maskY0 - OUTLINE_RADIUS)
		local x1, y1 = min(W - 1, maskX1 + OUTLINE_RADIUS), min(H - 1, maskY1 + OUTLINE_RADIUS)
		for y = y0, y1 do
			for x = x0, x1 do
				local idx = y * W + x
				if readu8(m, idx) ~= 0 then
					if fa > 0 then
						blend(target, idx * 4, fr, fg, fb, fa)
					end
				elseif oa > 0 then
					local near = false
					for oy = -OUTLINE_RADIUS, OUTLINE_RADIUS do
						local yy = y + oy
						if yy >= 0 and yy < H then
							for ox = -OUTLINE_RADIUS, OUTLINE_RADIUS do
								local xx = x + ox
								if xx >= 0 and xx < W and ox * ox + oy * oy <= R2 and readu8(m, yy * W + xx) ~= 0 then
									near = true
									break
								end
							end
						end
						if near then
							break
						end
					end
					if near then
						blend(target, idx * 4, orr, og, ob, oa)
					end
				end
			end
		end
	end

	local highlight = nil
	while p < count do
		local op = rd()
		if op == R.SHAPE then
			shape()
		elseif op == R.TRI then
			if shadowBuild then
				error("raster: TRI inside a shadow pass")
			end
			ensureDepth()
			triangle()
		elseif op == R.BALL then
			ensureDepth()
			ball()
		elseif op == R.MATERIAL then
			baseR, baseG, baseB, alpha, flags, emissive = rd(), rd(), rd(), rd(), rd(), rd()
			spec, shininess, reflect, fresnel = rd(), rd(), rd(), rd()
			local tex = rd()
			texture = if tex > 0 then textures[tex] else nil
			wrap = rd() ~= 0
		elseif op == R.CLIP then
			clip = { rd(), rd(), rd(), rd() }
		elseif op == R.LAYER then
			table.insert(layers, target)
			target = buffer.create(W * H * 4)
		elseif op == R.COMPOSITE then
			composite(rd(), rd(), rd(), rd())
		elseif op == R.FILL then
			local packed = pack(rd(), rd(), rd(), rd())
			for i = 0, W * H - 1 do
				writeu32(target, i * 4, packed)
			end
		elseif op == R.SKY then
			sky()
		elseif op == R.LIGHT then
			lx, ly, lz, ux, uy, uz = rd(), rd(), rd(), rd(), rd(), rd()
			lightR, lightG, lightB, ambR, ambG, ambB = rd(), rd(), rd(), rd(), rd(), rd()
			skyR, skyG, skyB, bounceR, bounceG, bounceB = rd(), rd(), rd(), rd(), rd(), rd()
			horR, horG, horB, zenR, zenG, zenB, grnR, grnG, grnB = rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd()
			envSpecular = rd()
		elseif op == R.CAMERA then
			f3, cx3, cy3 = rd(), rd(), rd()
		elseif op == R.FOG then
			fogStart, fogEnd, fogDensity, fogR, fogG, fogB = rd(), rd(), rd(), rd(), rd(), rd()
			fogOn = fogEnd > fogStart or fogDensity > 0
		elseif op == R.SHADOW_BEGIN then
			shadowSize = rd()
			for i = 1, 12 do
				sm[i] = rd()
			end
			shadowBias, shadowPcf = rd(), rd()
			shadowBuild = buffer.create(shadowSize * shadowSize * 4)
			-- empty texels are "nothing above": the lowest possible height
			for i = 0, shadowSize * shadowSize - 1 do
				writef32(shadowBuild, i * 4, -math.huge)
			end
		elseif op == R.SHADOW_TRI then
			shadowTri(shadowBuild, shadowSize)
		elseif op == R.SHADOW_BALL then
			shadowBall(shadowBuild, shadowSize)
		elseif op == R.SHADOW_END then
			shadowMap, shadowBuild = shadowBuild, nil
		elseif op == R.HIGHLIGHT_BEGIN then
			ensureDepth()
			maskMode = rd()
			highlight = { rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd(), rd() }
			mask = buffer.create(W * H)
			maskX0, maskY0, maskX1, maskY1 = W, H, -1, -1
		elseif op == R.HIGHLIGHT_END then
			local h = highlight
			finishHighlight(h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9])
		else
			error("raster: unknown op " .. op)
		end
		if yield then
			yield()
		end
	end
	return color
end

function R.upsample(src: buffer, width: number, height: number, scale: number, dst: buffer)
	local dw = width * scale
	for y = 0, height * scale - 1 do
		local sy = y // scale
		for x = 0, dw - 1 do
			writeu32(dst, (y * dw + x) * 4, readu32(src, (sy * width + x // scale) * 4))
		end
	end
end

-- Weights colour by alpha so transparent samples don't darken edges.
function R.downsample(src: buffer, width: number, height: number, scale: number, dst: buffer, yield)
	local sw = width * scale
	local n = scale * scale
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local r, g, b, a = 0, 0, 0, 0
			for sy = y * scale, y * scale + scale - 1 do
				local row = sy * sw
				for sx = x * scale, x * scale + scale - 1 do
					local p = readu32(src, (row + sx) * 4)
					local pa = rshift(p, 24)
					r += band(p, 255) * pa
					g += band(rshift(p, 8), 255) * pa
					b += band(rshift(p, 16), 255) * pa
					a += pa
				end
			end
			local out = 0
			if a > 0 then
				out = bor(floor(r / a + 0.5), lshift(floor(g / a + 0.5), 8), lshift(floor(b / a + 0.5), 16), lshift(floor(a / n + 0.5), 24))
			end
			writeu32(dst, (y * width + x) * 4, out)
		end
		if yield then
			yield()
		end
	end
end

return R
