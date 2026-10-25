--!native
--!optimize 2
-- Paints a GUI tree whose layout the engine has already resolved into an RGBA buffer.
-- Text uses a distance-field Source Sans atlas, stretched per label to the width the
-- real font measures, so it takes the space Roblox would give it.

local EncodingService = game:GetService("EncodingService")
local TextService = game:GetService("TextService")
local atlasData = require(script.Parent.fontAtlas)

local EM_PER_TEXTSIZE = 0.8
local EM, SPREAD, ATLAS_W = atlasData.em, atlasData.spread, atlasData.width
local QUESTION = 63

local M = {}

local fonts = {}
local function getFont(bold: boolean)
	local key = if bold then "bold" else "regular"
	local f = fonts[key]
	if f then
		return f
	end
	local src = atlasData[key]
	f = {
		pixels = EncodingService:DecompressBuffer(
			EncodingService:Base64Decode(buffer.fromstring(src.data)),
			Enum.CompressionAlgorithm.Zstd
		),
		ascender = src.ascender,
		descender = src.descender,
		glyphs = src.glyphs,
	}
	fonts[key] = f
	return f
end

local BOLD_FONTS = {}
for _, item in Enum.Font:GetEnumItems() do
	local n = item.Name
	if n:find("Bold") or n:find("Black") or n:find("Heavy") then
		BOLD_FONTS[item] = true
	end
end

local function isTextObject(obj)
	return obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")
end

local function isBold(label)
	local ok, face = pcall(function()
		return label.FontFace
	end)
	if ok and face then
		return face.Weight.Value >= Enum.FontWeight.SemiBold.Value
	end
	return BOLD_FONTS[label.Font] == true
end

local function clamp01(x)
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

local function codepoints(text: string)
	local out = {}
	if utf8.len(text) == nil then
		text = string.gsub(text, "[\128-\255]", "?")
	end
	for _, c in utf8.codes(text) do
		table.insert(out, c)
	end
	return out
end

local function stripRichText(text)
	text = string.gsub(text, "<br%s*/?>", "\n")
	text = string.gsub(text, "<[^<>]->", "")
	text = string.gsub(text, "&lt;", "<")
	text = string.gsub(text, "&gt;", ">")
	text = string.gsub(text, "&quot;", '"')
	text = string.gsub(text, "&apos;", "'")
	text = string.gsub(text, "&amp;", "&")
	return text
end

local function childOf(obj, class)
	for _, c in obj:GetChildren() do
		if c:IsA(class) and (not c:IsA("UIGradient") or c.Enabled) then
			return c
		end
	end
	return nil
end

--// text layout

local measureCache = {}
local function measureReal(text, size, label)
	local key = text .. "\0" .. size .. "\0" .. tostring(label.Font)
	local hit = measureCache[key]
	if hit ~= nil then
		return hit
	end
	local s = math.clamp(size, 1, 100)
	local width
	if label.Font ~= Enum.Font.Unknown then
		local ok, v = pcall(TextService.GetTextSize, TextService, text, s, label.Font, Vector2.new(1e6, 1e6))
		if ok then
			width = v.X * size / s
		end
	end
	if not width then
		local ok, v = pcall(function()
			local p = Instance.new("GetTextBoundsParams")
			p.Text, p.Font, p.Size, p.Width = text, label.FontFace, s, 1e6
			return TextService:GetTextBoundsAsync(p)
		end)
		width = if ok then v.X * size / s else nil
	end
	measureCache[key] = width or false
	return width or false
end

local function advance(f, cps, i0, i1)
	local w = 0
	local glyphs = f.glyphs
	for i = i0, i1 do
		w += (glyphs[cps[i]] or glyphs[QUESTION])[1]
	end
	return w
end

-- Lines as { first, last, width } with codepoint indices and atlas-unit widths.
local function wrapLines(f, cps, maxUnits)
	local lines = {}
	local glyphs = f.glyphs
	local n = #cps
	local start = 1
	for i = 1, n + 1 do
		if i > n or cps[i] == 10 then
			local a, b = start, i - 1
			if not maxUnits or a > b then
				table.insert(lines, { a, b, advance(f, cps, a, b) })
			else
				while a <= b do
					local width, lastSpace, j = 0, nil, a
					while j <= b do
						local adv = (glyphs[cps[j]] or glyphs[QUESTION])[1]
						if width + adv > maxUnits and j > a then
							break
						end
						width += adv
						if cps[j] == 32 then
							lastSpace = j
						end
						j += 1
					end
					if j > b then
						table.insert(lines, { a, b, width })
						break
					end
					local cut = if lastSpace and lastSpace > a then lastSpace else j - 1
					local e = cut
					while e > a and cps[e] == 32 do
						e -= 1
					end
					table.insert(lines, { a, e, advance(f, cps, a, e) })
					a = cut + 1
					while a <= b and cps[a] == 32 do
						a += 1
					end
				end
			end
			start = i + 1
		end
	end
	return lines
end

local function labelText(label)
	local text, color = label.Text, label.TextColor3
	if label:IsA("TextBox") and text == "" then
		text, color = label.PlaceholderText, label.PlaceholderColor3
	end
	if label.RichText then
		text = stripRichText(text)
	end
	return text, color
end

local function paddingOf(obj, w, h)
	local pad = childOf(obj, "UIPadding")
	if not pad then
		return 0, 0, 0, 0
	end
	return pad.PaddingLeft.Scale * w + pad.PaddingLeft.Offset,
		pad.PaddingTop.Scale * h + pad.PaddingTop.Offset,
		pad.PaddingRight.Scale * w + pad.PaddingRight.Offset,
		pad.PaddingBottom.Scale * h + pad.PaddingBottom.Offset
end

-- Shapes the label's text for a box; wrapW is nil when the text shouldn't wrap.
local function shape(label, text, size, wrapW)
	local f = getFont(isBold(label))
	local cps = codepoints(text)
	local flat = codepoints((string.gsub(text, "\n", " ")))
	local k = size * EM_PER_TEXTSIZE / EM
	local ours = advance(f, flat, 1, #flat) * k
	local real = measureReal((string.gsub(text, "\n", " ")), size, label)
	local fx = if real and ours > 0 then math.clamp(real / ours, 0.6, 1.6) else 1
	local kx = k * fx
	local lines = wrapLines(f, cps, if wrapW and wrapW > 0 then wrapW / kx else nil)
	local widest = 0
	for _, l in lines do
		widest = math.max(widest, l[3] * kx)
	end
	return {
		font = f,
		cps = cps,
		k = k,
		kx = kx,
		lines = lines,
		width = widest,
		height = (#lines - 1) * size * label.LineHeight + size,
		size = size,
	}
end

-- Content size of the label's text, for sizing AutomaticSize labels.
function M.textSize(label, wrapW: number?)
	local text = labelText(label)
	if text == "" then
		return Vector2.new(0, label.TextSize)
	end
	local s = shape(label, text, label.TextSize, if label.TextWrapped then wrapW else nil)
	return Vector2.new(math.ceil(s.width), math.ceil(s.height))
end

M.paddingOf = paddingOf
M.isTextObject = isTextObject

-- "Over" composite of a straight-alpha colour into an RGBA buffer at byte offset i.
local function blendInto(buf, i, r, g, b, a)
	if a <= 0.002 then
		return
	end
	if a >= 0.998 then
		buffer.writeu32(buf, i, bit32.bor(
			math.floor(clamp01(r) * 255 + 0.5),
			bit32.lshift(math.floor(clamp01(g) * 255 + 0.5), 8),
			bit32.lshift(math.floor(clamp01(b) * 255 + 0.5), 16),
			0xFF000000
		))
		return
	end
	local dst = buffer.readu32(buf, i)
	local da = bit32.rshift(dst, 24) / 255
	local oa = a + da * (1 - a)
	local k = da * (1 - a)
	buffer.writeu32(buf, i, bit32.bor(
		math.floor(clamp01((r * a + (bit32.band(dst, 255) / 255) * k) / oa) * 255 + 0.5),
		bit32.lshift(math.floor(clamp01((g * a + (bit32.band(bit32.rshift(dst, 8), 255) / 255) * k) / oa) * 255 + 0.5), 8),
		bit32.lshift(math.floor(clamp01((b * a + (bit32.band(bit32.rshift(dst, 16), 255) / 255) * k) / oa) * 255 + 0.5), 16),
		bit32.lshift(math.floor(clamp01(oa) * 255 + 0.5), 24)
	))
end

-- o: size, font (Enum.Font), lineHeight, maxWidth (wraps), align ("Left" | "Center" | "Right")
local function plainShape(text, o)
	local label = { Font = o.font or Enum.Font.SourceSans, LineHeight = o.lineHeight or 1 }
	return shape(label, text, o.size, o.maxWidth)
end

function M.measureText(text: string, o)
	if text == "" then
		return Vector2.zero
	end
	local s = plainShape(text, o)
	return Vector2.new(math.ceil(s.width), math.ceil(s.height))
end

-- Draws text straight into a W x H RGBA buffer with its line box's top-left at (x, y),
-- or with the top of its capitals at y when o.capTop is set. Returns the text's size.
function M.drawText(dst, W, H, text: string, x, y, color: Color3, alpha, o)
	if text == "" or alpha <= 0 then
		return Vector2.zero
	end
	local s = plainShape(text, o)
	local f, k, kx, cps, size = s.font, s.k, s.kx, s.cps, s.size
	local baseOff = (size - (f.ascender - f.descender) * k) / 2 + f.ascender * k
	local top = y
	if o.capTop then
		local cap = f.glyphs[72]
		top = y - (baseOff + (cap[7] + SPREAD) * k)
	end
	local blockW = o.maxWidth or s.width
	local factor = if o.align == "Center" then 0.5 elseif o.align == "Right" then 1 else 0
	local lineStep = size * (o.lineHeight or 1)
	local glyphs = f.glyphs
	local quads = {}
	for li, line in s.lines do
		local px = x + (blockW - line[3] * kx) * factor
		local baseline = top + (li - 1) * lineStep + baseOff
		for i = line[1], line[2] do
			local g = glyphs[cps[i]] or glyphs[QUESTION]
			if g[4] > 0 then
				table.insert(quads, { g, px + g[6] * kx, baseline + g[7] * k })
			end
			px += g[1] * kx
		end
	end

	local pixels = f.pixels
	local distScale = math.min(k, kx) * 2 * SPREAD / 255
	local function raster(extra, cr, cg, cb, ca)
		for _, q in quads do
			local g, qx, qy = q[1], q[2], q[3]
			local gx, gy, gw, gh = g[2], g[3], g[4], g[5]
			local x0, x1 = math.max(0, math.floor(qx)), math.min(W - 1, math.ceil(qx + gw * kx) - 1)
			local y0, y1 = math.max(0, math.floor(qy)), math.min(H - 1, math.ceil(qy + gh * k) - 1)
			for py = y0, y1 do
				local ay = (py + 0.5 - qy) / k - 0.5
				if ay < 0 then ay = 0 elseif ay > gh - 1 then ay = gh - 1 end
				local iy = math.floor(ay)
				local ty = ay - iy
				local row0 = (gy + iy) * ATLAS_W + gx
				local row1 = (gy + math.min(iy + 1, gh - 1)) * ATLAS_W + gx
				for px = x0, x1 do
					local ax = (px + 0.5 - qx) / kx - 0.5
					if ax < 0 then ax = 0 elseif ax > gw - 1 then ax = gw - 1 end
					local ix = math.floor(ax)
					local tx = ax - ix
					local ix1 = math.min(ix + 1, gw - 1)
					local s00, s10 = buffer.readu8(pixels, row0 + ix), buffer.readu8(pixels, row0 + ix1)
					local s01, s11 = buffer.readu8(pixels, row1 + ix), buffer.readu8(pixels, row1 + ix1)
					local t0 = s00 + (s10 - s00) * tx
					local val = t0 + ((s01 + (s11 - s01) * tx) - t0) * ty
					local cov = clamp01((val - 127.5) * distScale + 0.5 + extra)
					if cov > 0 then
						blendInto(dst, (py * W + px) * 4, cr, cg, cb, ca * cov)
					end
				end
			end
		end
	end
	if o.stroke then
		local t = math.min(o.strokeThickness or 1, SPREAD * math.min(k, kx) - 0.5)
		local sc = o.stroke
		raster(t, sc.R, sc.G, sc.B, alpha * (1 - (o.strokeTransparency or 0)))
	end
	raster(0, color.R, color.G, color.B, alpha)
	return Vector2.new(math.ceil(s.width), math.ceil(s.height))
end

--// geometry helpers

local function seqColor(seq: ColorSequence, t)
	local kp = seq.Keypoints
	if t <= kp[1].Time then
		return kp[1].Value
	end
	for i = 2, #kp do
		local b = kp[i]
		if t <= b.Time then
			local a = kp[i - 1]
			local span = b.Time - a.Time
			return a.Value:Lerp(b.Value, if span > 0 then (t - a.Time) / span else 0)
		end
	end
	return kp[#kp].Value
end

local function seqNumber(seq: NumberSequence, t)
	local kp = seq.Keypoints
	if t <= kp[1].Time then
		return kp[1].Value
	end
	for i = 2, #kp do
		local b = kp[i]
		if t <= b.Time then
			local a = kp[i - 1]
			local span = b.Time - a.Time
			return a.Value + (b.Value - a.Value) * (if span > 0 then (t - a.Time) / span else 0)
		end
	end
	return kp[#kp].Value
end

-- Signed distance to a rounded rect spanning [x0, x1] x [y0, y1]; negative inside.
local function rrDist(u, v, x0, y0, x1, y1, r)
	local hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
	local qx = math.abs(u - x0 - hw) - (hw - r)
	local qy = math.abs(v - y0 - hh) - (hh - r)
	local ox, oy = math.max(qx, 0), math.max(qy, 0)
	return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0) - r
end

local function gradientFor(obj, w, h)
	local grad = childOf(obj, "UIGradient")
	if not grad then
		return nil
	end
	local rot = math.rad(grad.Rotation)
	local c, s = math.cos(rot), math.sin(rot)
	local off = grad.Offset
	local cs, ns = grad.Color, grad.Transparency
	return function(u, v)
		local x, y = u / w - 0.5 - off.X, v / h - 0.5 - off.Y
		local t = math.clamp(x * c + y * s + 0.5, 0, 1)
		local col = seqColor(cs, t)
		return col.R, col.G, col.B, 1 - seqNumber(ns, t)
	end
end

function M.paint(root: Instance, opts)
	local W, H = opts.width, opts.height
	local originX, originY = opts.origin.X, opts.origin.Y
	local color = opts.target or buffer.create(W * H * 4)

	local function blend(idx, r, g, b, a)
		if a <= 0.002 then
			return
		end
		local i = idx * 4
		if a >= 0.998 then
			buffer.writeu32(color, i, bit32.bor(
				math.floor(clamp01(r) * 255 + 0.5),
				bit32.lshift(math.floor(clamp01(g) * 255 + 0.5), 8),
				bit32.lshift(math.floor(clamp01(b) * 255 + 0.5), 16),
				0xFF000000
			))
			return
		end
		local dst = buffer.readu32(color, i)
		local da = bit32.rshift(dst, 24) / 255
		local oa = a + da * (1 - a)
		local k = da * (1 - a)
		buffer.writeu32(color, i, bit32.bor(
			math.floor(clamp01((r * a + (bit32.band(dst, 255) / 255) * k) / oa) * 255 + 0.5),
			bit32.lshift(math.floor(clamp01((g * a + (bit32.band(bit32.rshift(dst, 8), 255) / 255) * k) / oa) * 255 + 0.5), 8),
			bit32.lshift(math.floor(clamp01((b * a + (bit32.band(bit32.rshift(dst, 16), 255) / 255) * k) / oa) * 255 + 0.5), 16),
			bit32.lshift(math.floor(clamp01(oa) * 255 + 0.5), 24)
		))
	end

	-- Calls shade(u, v) for every output pixel whose centre falls in the local rect
	-- [lx0, lx1] x [ly0, ly1] of the object, through its rotation and clip.
	local function paint(geom, lx0, ly0, lx1, ly1, shade)
		local clip = geom.clip
		if geom.rot == 0 then
			local sx0 = math.max(clip[1], math.floor(geom.x + lx0))
			local sy0 = math.max(clip[2], math.floor(geom.y + ly0))
			local sx1 = math.min(clip[3], math.ceil(geom.x + lx1)) - 1
			local sy1 = math.min(clip[4], math.ceil(geom.y + ly1)) - 1
			for sy = sy0, sy1 do
				local v = sy + 0.5 - geom.y
				if v < ly0 or v > ly1 then
					continue
				end
				local row = sy * W
				for sx = sx0, sx1 do
					local u = sx + 0.5 - geom.x
					if u >= lx0 and u <= lx1 then
						local r, g, b, a = shade(u, v)
						if a > 0 then
							blend(row + sx, r, g, b, a)
						end
					end
				end
			end
			return
		end
		local c, s = geom.cos, geom.sin
		local cx, cy = geom.cx, geom.cy
		local hw, hh = geom.w / 2, geom.h / 2
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		for _, p in { { lx0, ly0 }, { lx1, ly0 }, { lx0, ly1 }, { lx1, ly1 } } do
			local dx, dy = p[1] - hw, p[2] - hh
			local x, y = cx + dx * c - dy * s, cy + dx * s + dy * c
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
		end
		local sx0, sy0 = math.max(clip[1], math.floor(minX)), math.max(clip[2], math.floor(minY))
		local sx1, sy1 = math.min(clip[3], math.ceil(maxX)) - 1, math.min(clip[4], math.ceil(maxY)) - 1
		for sy = sy0, sy1 do
			local dy = sy + 0.5 - cy
			local row = sy * W
			for sx = sx0, sx1 do
				local dx = sx + 0.5 - cx
				local u = dx * c + dy * s + hw
				local v = -dx * s + dy * c + hh
				if u >= lx0 and u <= lx1 and v >= ly0 and v <= ly1 then
					local r, g, b, a = shade(u, v)
					if a > 0 then
						blend(row + sx, r, g, b, a)
					end
				end
			end
		end
	end

	local function drawText(geom, label, groupAlpha, gradient, stroke)
		local text, textColor = labelText(label)
		local textAlpha = (1 - label.TextTransparency) * groupAlpha
		if text == "" or textAlpha <= 0 then
			return
		end
		local pl, pt, pr, pb = paddingOf(label, geom.w, geom.h)
		local bx0, by0, bx1, by1 = pl, pt, geom.w - pr, geom.h - pb
		local boxW, boxH = math.max(0, bx1 - bx0), math.max(0, by1 - by0)
		local wrapW = if label.TextWrapped then boxW else nil

		local size = label.TextSize
		if label.TextScaled then
			local lo, hi = 1, 100
			while lo < hi do
				local mid = (lo + hi + 1) // 2
				local s = shape(label, text, mid, wrapW)
				if s.width <= boxW + 0.5 and s.height <= boxH + 0.5 then
					lo = mid
				else
					hi = mid - 1
				end
			end
			size = lo
		end
		local s = shape(label, text, size, wrapW)
		local f, k, kx, cps = s.font, s.k, s.kx, s.cps

		local yAlign = label.TextYAlignment
		local top = if yAlign == Enum.TextYAlignment.Top
			then by0
			elseif yAlign == Enum.TextYAlignment.Bottom then by1 - s.height
			else by0 + (boxH - s.height) / 2
		local baseOff = (size - (f.ascender - f.descender) * k) / 2 + f.ascender * k
		local xAlign = label.TextXAlignment
		local lineStep = size * label.LineHeight

		local strokeT, sr, sg, sb, sa = 0, 0, 0, 0, 0
		if stroke then
			strokeT = stroke.Thickness
			sr, sg, sb = stroke.Color.R, stroke.Color.G, stroke.Color.B
			sa = (1 - stroke.Transparency) * groupAlpha
		elseif label.TextStrokeTransparency < 1 then
			strokeT = 1
			local c = label.TextStrokeColor3
			sr, sg, sb = c.R, c.G, c.B
			sa = (1 - label.TextStrokeTransparency) * groupAlpha
		end
		strokeT = math.min(strokeT, SPREAD * math.min(k, kx) - 0.5)

		local glyphs, pixels = f.glyphs, f.pixels
		local quads = {}
		for li, line in s.lines do
			local width = line[3] * kx
			local x = if xAlign == Enum.TextXAlignment.Left
				then bx0
				elseif xAlign == Enum.TextXAlignment.Right then bx1 - width
				else bx0 + (boxW - width) / 2
			local baseline = top + (li - 1) * lineStep + baseOff
			for i = line[1], line[2] do
				local g = glyphs[cps[i]] or glyphs[QUESTION]
				if g[4] > 0 then
					table.insert(quads, { g, x + g[6] * kx, baseline + g[7] * k })
				end
				x += g[1] * kx
			end
		end

		local distScale = math.min(k, kx) * 2 * SPREAD / 255
		local function sampler(q, extra, cr, cg, cb, ca)
			local g, qx, qy = q[1], q[2], q[3]
			local gx, gy, gw, gh = g[2], g[3], g[4], g[5]
			return function(u, v)
				local ax = (u - qx) / kx - 0.5
				local ay = (v - qy) / k - 0.5
				if ax < 0 then ax = 0 elseif ax > gw - 1 then ax = gw - 1 end
				if ay < 0 then ay = 0 elseif ay > gh - 1 then ay = gh - 1 end
				local ix, iy = math.floor(ax), math.floor(ay)
				local tx, ty = ax - ix, ay - iy
				local ix1, iy1 = math.min(ix + 1, gw - 1), math.min(iy + 1, gh - 1)
				local row0, row1 = (gy + iy) * ATLAS_W + gx, (gy + iy1) * ATLAS_W + gx
				local s00 = buffer.readu8(pixels, row0 + ix)
				local s10 = buffer.readu8(pixels, row0 + ix1)
				local s01 = buffer.readu8(pixels, row1 + ix)
				local s11 = buffer.readu8(pixels, row1 + ix1)
				local top0 = s00 + (s10 - s00) * tx
				local val = top0 + ((s01 + (s11 - s01) * tx) - top0) * ty
				local cov = clamp01((val - 127.5) * distScale + 0.5 + extra)
				if cov <= 0 then
					return 0, 0, 0, 0
				end
				local r, gg, b, a = cr, cg, cb, ca * cov
				if gradient then
					local gr, ga2, gbl, gaa = gradient(u, v)
					r, gg, b, a = r * gr, gg * ga2, b * gbl, a * gaa
				end
				return r, gg, b, a
			end
		end
		if strokeT > 0 and sa > 0 then
			for _, q in quads do
				local g = q[1]
				paint(geom, q[2], q[3], q[2] + g[4] * kx, q[3] + g[5] * k, sampler(q, strokeT, sr, sg, sb, sa))
			end
		end
		local tr, tg, tb = textColor.R, textColor.G, textColor.B
		for _, q in quads do
			local g = q[1]
			paint(geom, q[2], q[3], q[2] + g[4] * kx, q[3] + g[5] * k, sampler(q, 0, tr, tg, tb, textAlpha))
		end
	end

	local function drawImage(geom, obj, img, radius, groupAlpha, gradient)
		local iw, ih = img.Size.X, img.Size.Y
		local src = img.imageBuffer
		local rx, ry, rw, rh = 0, 0, iw, ih
		local isViewport = obj:IsA("ViewportFrame")
		local tint, alpha, scaleType = Color3.new(1, 1, 1), groupAlpha, Enum.ScaleType.Stretch
		if not isViewport then
			local rectSize = obj.ImageRectSize
			if rectSize.X > 0 and rectSize.Y > 0 then
				local off = obj.ImageRectOffset
				rx, ry = math.clamp(off.X, 0, iw - 1), math.clamp(off.Y, 0, ih - 1)
				rw, rh = math.max(1, math.min(rectSize.X, iw - rx)), math.max(1, math.min(rectSize.Y, ih - ry))
			end
			tint, alpha, scaleType = obj.ImageColor3, (1 - obj.ImageTransparency) * groupAlpha, obj.ScaleType
		end
		if alpha <= 0 then
			return
		end
		local w, h = geom.w, geom.h
		local dx0, dy0, dw, dh = 0, 0, w, h
		if scaleType == Enum.ScaleType.Fit or scaleType == Enum.ScaleType.Crop then
			local sc = if scaleType == Enum.ScaleType.Fit then math.min(w / rw, h / rh) else math.max(w / rw, h / rh)
			dw, dh = rw * sc, rh * sc
			dx0, dy0 = (w - dw) / 2, (h - dh) / 2
		end
		local tileW, tileH
		if scaleType == Enum.ScaleType.Tile then
			local ts = obj.TileSize
			tileW = math.max(1, ts.X.Scale * w + ts.X.Offset)
			tileH = math.max(1, ts.Y.Scale * h + ts.Y.Offset)
		end
		local slice = scaleType == Enum.ScaleType.Slice
		local sl, st, sr2, sb2, ss = 0, 0, 0, 0, 1
		if slice then
			local c = obj.SliceCenter
			sl, st = math.max(0, c.Min.X - rx), math.max(0, c.Min.Y - ry)
			sr2, sb2 = math.max(0, rw - (c.Max.X - rx)), math.max(0, rh - (c.Max.Y - ry))
			ss = obj.SliceScale
		end
		local tr, tg, tb = tint.R, tint.G, tint.B
		local pixelated = not isViewport and obj.ResampleMode == Enum.ResamplerMode.Pixelated
		local function axis(p, d0, dlen, len, lo, hi)
			if slice then
				local a, b = lo * ss, hi * ss
				if p < a then
					return p / ss
				elseif p > dlen - b then
					return len - (dlen - p) / ss
				end
				local mid = dlen - a - b
				return lo + (if mid > 0 then (p - a) / mid else 0) * (len - lo - hi)
			end
			return (p - d0) / dlen * len
		end
		paint(geom, math.max(0, dx0), math.max(0, dy0), math.min(w, dx0 + dw), math.min(h, dy0 + dh), function(u, v)
			local cov = 1
			if radius > 0 then
				cov = clamp01(0.5 - rrDist(u, v, 0, 0, w, h, radius))
				if cov <= 0 then
					return 0, 0, 0, 0
				end
			end
			local sx, sy
			if tileW then
				sx, sy = (u % tileW) / tileW * rw, (v % tileH) / tileH * rh
			else
				sx, sy = axis(u, dx0, dw, rw, sl, sr2), axis(v, dy0, dh, rh, st, sb2)
			end
			local ix, iy, fx, fy
			if pixelated then
				ix, iy = math.floor(math.clamp(sx, 0, rw - 1e-3)) + rx, math.floor(math.clamp(sy, 0, rh - 1e-3)) + ry
				fx, fy = 0, 0
			else
				sx = math.clamp(sx - 0.5, 0, rw - 1) + rx
				sy = math.clamp(sy - 0.5, 0, rh - 1) + ry
				ix, iy = math.floor(sx), math.floor(sy)
				fx, fy = sx - ix, sy - iy
			end
			local ix1, iy1 = math.min(ix + 1, iw - 1), math.min(iy + 1, ih - 1)
			local p00 = buffer.readu32(src, (iy * iw + ix) * 4)
			local p10 = buffer.readu32(src, (iy * iw + ix1) * 4)
			local p01 = buffer.readu32(src, (iy1 * iw + ix) * 4)
			local p11 = buffer.readu32(src, (iy1 * iw + ix1) * 4)
			local function ch(shift)
				local a = bit32.band(bit32.rshift(p00, shift), 255)
				local b = bit32.band(bit32.rshift(p10, shift), 255)
				local c = bit32.band(bit32.rshift(p01, shift), 255)
				local d = bit32.band(bit32.rshift(p11, shift), 255)
				local t0 = a + (b - a) * fx
				return (t0 + ((c + (d - c) * fx) - t0) * fy) / 255
			end
			local a = ch(24) * alpha * cov
			if a <= 0 then
				return 0, 0, 0, 0
			end
			local r, g, b = ch(0) * tr, ch(8) * tg, ch(16) * tb
			if gradient then
				local gr, gg, gb, ga = gradient(u, v)
				r, g, b, a = r * gr, g * gg, b * gb, a * ga
			end
			return r, g, b, a
		end)
	end

	local function drawObject(obj: GuiObject, clip, groupAlpha)
		local pos, size = obj.AbsolutePosition, obj.AbsoluteSize
		local w, h = size.X, size.Y
		if w <= 0 or h <= 0 then
			return
		end
		local rot = math.rad(obj.AbsoluteRotation)
		local x, y = pos.X - originX, pos.Y - originY
		local geom = {
			x = x, y = y, w = w, h = h, rot = rot, clip = clip,
			cos = math.cos(rot), sin = math.sin(rot), cx = x + w / 2, cy = y + h / 2,
		}
		local corner = childOf(obj, "UICorner")
		local radius = 0
		if corner then
			radius = math.clamp(corner.CornerRadius.Scale * math.min(w, h) + corner.CornerRadius.Offset, 0, math.min(w, h) / 2)
		end
		local gradient = gradientFor(obj, w, h)

		local bgAlpha = (1 - obj.BackgroundTransparency) * groupAlpha
		if bgAlpha > 0 then
			local bg = obj.BackgroundColor3
			local br, bgc, bb = bg.R, bg.G, bg.B
			paint(geom, 0, 0, w, h, function(u, v)
				local cov = if radius > 0 then clamp01(0.5 - rrDist(u, v, 0, 0, w, h, radius)) else 1
				local r, g, b, a = br, bgc, bb, bgAlpha * cov
				if gradient then
					local gr, gg, gb, ga = gradient(u, v)
					r, g, b, a = r * gr, g * gg, b * gb, a * ga
				end
				return r, g, b, a
			end)
			local border = obj.BorderSizePixel
			if border > 0 and radius == 0 then
				local bc = obj.BorderColor3
				local mode = obj.BorderMode
				local o = if mode == Enum.BorderMode.Outline then border elseif mode == Enum.BorderMode.Middle then border / 2 else 0
				local i = border - o
				local cr, cg, cb = bc.R, bc.G, bc.B
				paint(geom, -o, -o, w + o, h + o, function(u, v)
					local outer = clamp01(0.5 - rrDist(u, v, -o, -o, w + o, h + o, 0))
					local inner = clamp01(0.5 - rrDist(u, v, i, i, w - i, h - i, 0))
					return cr, cg, cb, bgAlpha * math.max(0, outer - inner)
				end)
			end
		end

		local img = opts.imageFor(obj, w, h)
		if img then
			drawImage(geom, obj, img, radius, groupAlpha, gradient)
		end

		local text = isTextObject(obj)
		local textStroke, borderStrokes = nil, {}
		for _, c in obj:GetChildren() do
			if c:IsA("UIStroke") and c.Enabled then
				if text and c.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
					textStroke = textStroke or c
				else
					table.insert(borderStrokes, c)
				end
			end
		end
		if text then
			drawText(geom, obj, groupAlpha, gradient, textStroke)
		end

		for _, stroke in borderStrokes do
			local t = stroke.Thickness
			local sa = (1 - stroke.Transparency) * groupAlpha
			if t <= 0 or sa <= 0 then
				continue
			end
			local posMode = "Outer"
			pcall(function()
				posMode = stroke.BorderStrokePosition.Name
			end)
			local o = if posMode == "Outer" then t elseif posMode == "Center" then t / 2 else 0
			local i = t - o
			local sc = stroke.Color
			local sr, sg, sb = sc.R, sc.G, sc.B
			local sgrad = gradientFor(stroke, w, h)
			paint(geom, -o - 1, -o - 1, w + o + 1, h + o + 1, function(u, v)
				local d = rrDist(u, v, 0, 0, w, h, radius)
				local cov = clamp01(0.5 - (d - o)) - clamp01(0.5 - (d + i))
				if cov <= 0 then
					return 0, 0, 0, 0
				end
				local r, g, b, a = sr, sg, sb, sa * cov
				if sgrad then
					local gr, gg, gb, ga = sgrad(u, v)
					r, g, b, a = r * gr, g * gg, b * gb, a * ga
				end
				return r, g, b, a
			end)
		end
	end

	local full = { 0, 0, W, H }
	local function childClip(obj, clip)
		if obj:IsA("GuiObject") and (obj.ClipsDescendants or obj:IsA("ScrollingFrame")) and obj.AbsoluteRotation == 0 then
			local p, sz = obj.AbsolutePosition, obj.AbsoluteSize
			return {
				math.max(clip[1], math.floor(p.X - originX + 0.5)),
				math.max(clip[2], math.floor(p.Y - originY + 0.5)),
				math.min(clip[3], math.floor(p.X - originX + sz.X + 0.5)),
				math.min(clip[4], math.floor(p.Y - originY + sz.Y + 0.5)),
			}
		end
		return clip
	end

	-- Folders are see-through: their GuiObjects draw as children of the folder's parent
	local function sortedChildren(obj)
		local list = {}
		local n = 0
		local function add(parent)
			for _, c in parent:GetChildren() do
				if c:IsA("GuiObject") then
					n += 1
					table.insert(list, { c, n })
				elseif c:IsA("Folder") then
					add(c)
				end
			end
		end
		add(obj)
		table.sort(list, function(a, b)
			if a[1].ZIndex ~= b[1].ZIndex then
				return a[1].ZIndex < b[1].ZIndex
			end
			return a[2] < b[2]
		end)
		return list
	end

	local function groupOf(obj, groupAlpha)
		if obj:IsA("CanvasGroup") then
			return groupAlpha * (1 - obj.GroupTransparency)
		end
		return groupAlpha
	end

	if opts.global then
		local all = {}
		local function collect(obj, clip, groupAlpha)
			for _, entry in sortedChildren(obj) do
				local c = entry[1]
				if c.Visible then
					local ga = groupOf(c, groupAlpha)
					table.insert(all, { c, clip, ga, #all })
					collect(c, childClip(c, clip), ga)
				end
			end
		end
		if root:IsA("GuiObject") then
			if root.Visible then
				local ga = groupOf(root, 1)
				table.insert(all, { root, full, ga, 0 })
				collect(root, childClip(root, full), ga)
			end
		else
			collect(root, full, 1)
		end
		table.sort(all, function(a, b)
			if a[1].ZIndex ~= b[1].ZIndex then
				return a[1].ZIndex < b[1].ZIndex
			end
			return a[4] < b[4]
		end)
		for _, e in all do
			drawObject(e[1], e[2], e[3])
			opts.yield()
		end
	else
		local function walk(obj, clip, groupAlpha)
			for _, entry in sortedChildren(obj) do
				local c = entry[1]
				if c.Visible then
					local ga = groupOf(c, groupAlpha)
					drawObject(c, clip, ga)
					opts.yield()
					walk(c, childClip(c, clip), ga)
				end
			end
		end
		if root:IsA("GuiObject") then
			if root.Visible then
				local ga = groupOf(root, 1)
				drawObject(root, full, ga)
				walk(root, childClip(root, full), ga)
			end
		else
			walk(root, full, 1)
		end
	end

	return color
end

return M
