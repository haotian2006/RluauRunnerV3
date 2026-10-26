--!native
--!optimize 2

local EncodingService = game:GetService("EncodingService")
local TextService = game:GetService("TextService")
local atlasData = require(script.Parent.fontAtlas)
local arimoData = require(script.Parent.fontAtlasArimo)

local EM, SPREAD, ATLAS_W = atlasData.em, atlasData.spread, atlasData.width
assert(arimoData.em == EM and arimoData.spread == SPREAD and arimoData.width == ATLAS_W, "font atlases differ in layout")
local QUESTION = 63
-- Legacy draws Arial at 1.5x TextSize (TextService agrees)
local LEGACY_SCALE = 1.5

-- Roblox scales a font so its hhea ascent - descent spans TextSize: Source Sans Pro is 1.257 em,
-- Arial/Arimo 1.117 em
local FAMILIES = {
	sans = { data = atlasData, emPerTextSize = 0.8 },
	arial = { data = arimoData, emPerTextSize = EM / (arimoData.regular.ascender - arimoData.regular.descender) },
}

local M = {}

local fonts = {}
local function getFont(bold: boolean, arial: boolean?)
	local family = if arial then "arial" else "sans"
	local key = family .. if bold then "bold" else "regular"
	local f = fonts[key]
	if f then
		return f
	end
	local fam = FAMILIES[family]
	local src = fam.data[if bold then "bold" else "regular"]
	f = {
		pixels = EncodingService:DecompressBuffer(
			EncodingService:Base64Decode(buffer.fromstring(src.data)),
			Enum.CompressionAlgorithm.Zstd
		),
		ascender = src.ascender,
		descender = src.descender,
		glyphs = src.glyphs,
		height = src.height,
		emPerTextSize = fam.emPerTextSize,
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

local ARIAL_FONTS = { [Enum.Font.Legacy] = true, [Enum.Font.Arial] = true, [Enum.Font.ArialBold] = true }

local function arialFamily(label): (boolean, number)
	local ok, face = pcall(function()
		return label.FontFace
	end)
	if ok and face then
		local fam = string.lower(face.Family)
		local legacy = string.find(fam, "legacy", 1, true) ~= nil
		local arial = legacy or string.find(fam, "arial", 1, true) ~= nil or string.find(fam, "arimo", 1, true) ~= nil
		return arial, if legacy then LEGACY_SCALE else 1
	end
	return ARIAL_FONTS[label.Font] == true, if label.Font == Enum.Font.Legacy then LEGACY_SCALE else 1
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

local measureCache = {}
-- size is the drawn size (TextSize x the Legacy multiplier); TextService applies that itself.
local function measureReal(text, size, label)
	local fontKey = if label.Font == Enum.Font.Unknown then tostring(label.FontFace) else tostring(label.Font)
	local key = text .. "\0" .. size .. "\0" .. fontKey
	local hit = measureCache[key]
	if hit ~= nil then
		return hit
	end
	local _, mul = arialFamily(label)
	size /= mul
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

local function shape(label, text, size, wrapW)
	local arial, mul = arialFamily(label)
	size *= mul
	local f = getFont(isBold(label), arial)
	local cps = codepoints(text)
	local flat = codepoints((string.gsub(text, "\n", " ")))
	local k = size * f.emPerTextSize / EM
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

function M.textSize(label, wrapW: number?)
	local text = labelText(label)
	if text == "" then
		local _, mul = arialFamily(label)
		return Vector2.new(0, label.TextSize * mul)
	end
	local s = shape(label, text, label.TextSize, if label.TextWrapped then wrapW else nil)
	return Vector2.new(math.ceil(s.width), math.ceil(s.height))
end

M.paddingOf = paddingOf
M.isTextObject = isTextObject

-- Expects straight alpha.
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

-- (x, y) is the line box's top-left, or the cap top when o.capTop is set.
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

local R = require(script.Parent.raster)

local ELLIPSIS = 8230
local ITALIC_SHEAR = 0.2
local PATH_STEPS = 24
local COVER_FULL = { R.FULL }
local GRAD_NONE = { 0 }

local function solid(c: Color3, a)
	return { R.SOLID, c.R, c.G, c.B, a }
end

-- Product of the UIScales on obj and its ancestors up to stop: the engine scales layout, the
-- painter scales offsets (text size, padding, corners, strokes) the same way.
local function uiScaleOf(obj, stop)
	local s = 1
	local cur = obj
	while cur do
		local ui = cur:FindFirstChildOfClass("UIScale")
		if ui then
			s *= ui.Scale
		end
		if cur == stop then
			break
		end
		cur = cur.Parent
	end
	return s
end

local function scaledPadding(obj, w, h, scale)
	local pad = childOf(obj, "UIPadding")
	if not pad then
		return 0, 0, 0, 0
	end
	return pad.PaddingLeft.Scale * w + pad.PaddingLeft.Offset * scale,
		pad.PaddingTop.Scale * h + pad.PaddingTop.Offset * scale,
		pad.PaddingRight.Scale * w + pad.PaddingRight.Offset * scale,
		pad.PaddingBottom.Scale * h + pad.PaddingBottom.Offset * scale
end

-- Corner radii (top-left, top-right, bottom-left, bottom-right) from a UICorner.
local function cornerRadii(obj, w, h, scale)
	local corner = childOf(obj, "UICorner")
	if not corner then
		return 0, 0, 0, 0
	end
	local m = math.min(w, h)
	local function r(u: UDim)
		return math.clamp(u.Scale * m + u.Offset * scale, 0, m / 2)
	end
	local ok, tl, tr, bl, br = pcall(function()
		return corner.TopLeftRadius, corner.TopRightRadius, corner.BottomLeftRadius, corner.BottomRightRadius
	end)
	-- per-corner radii only when they differ; otherwise CornerRadius is what was set
	if ok and not (tl == tr and tr == bl and bl == br) then
		return r(tl), r(tr), r(bl), r(br)
	end
	local c = r(corner.CornerRadius)
	return c, c, c, c
end

local function gradientList(obj, w, h)
	local grad = childOf(obj, "UIGradient")
	if not grad then
		return GRAD_NONE
	end
	local rot = math.rad(grad.Rotation)
	local list = { 1, math.cos(rot), math.sin(rot), grad.Offset.X, grad.Offset.Y, w, h }
	local ck = grad.Color.Keypoints
	table.insert(list, #ck)
	for _, kp in ck do
		table.insert(list, kp.Time)
		table.insert(list, kp.Value.R)
		table.insert(list, kp.Value.G)
		table.insert(list, kp.Value.B)
	end
	local tk = grad.Transparency.Keypoints
	table.insert(list, #tk)
	for _, kp in tk do
		table.insert(list, kp.Time)
		table.insert(list, kp.Value)
	end
	return list
end

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

local function decodeEntities(s)
	return (string.gsub(s, "&(%a+);", function(name)
		return ENTITIES[name]
	end))
end

local function parseColor(s: string?): (number?, number?, number?)
	if not s then
		return nil
	end
	local hex = string.match(s, "^%s*#(%x+)%s*$")
	if hex and #hex == 6 then
		return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
	elseif hex and #hex == 3 then
		return tonumber(hex:sub(1, 1), 16) * 17 / 255, tonumber(hex:sub(2, 2), 16) * 17 / 255, tonumber(hex:sub(3, 3), 16) * 17 / 255
	end
	local r, g, b = string.match(s, "^%s*rgb%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)%s*$")
	if r then
		return math.min(tonumber(r) :: number, 255) / 255, math.min(tonumber(g) :: number, 255) / 255, math.min(tonumber(b) :: number, 255) / 255
	end
	return nil
end

local function attributes(tag)
	local out = {}
	for k, v in string.gmatch(tag, "([%a_]+)%s*=%s*\"([^\"]*)\"") do
		out[string.lower(k)] = v
	end
	for k, v in string.gmatch(tag, "([%a_]+)%s*=%s*'([^']*)'") do
		out[string.lower(k)] = v
	end
	return out
end

local WEIGHTS = { bold = true, heavy = true, semibold = true, extrabold = true, black = true }

local function addCodepoints(items, text, style)
	if style.upper then
		text = string.upper(text)
	end
	if utf8.len(text) == nil then
		text = string.gsub(text, "[\128-\255]", "?")
	end
	for _, c in utf8.codes(text) do
		table.insert(items, { cp = c, s = style })
	end
end

-- Styles are { r, g, b, alpha, size, bold, italic, underline, strike, upper, stroke }; unknown tags are dropped.
local function richItems(text, base)
	local items = {}
	local stack = { base }
	local function push(changes)
		local s = table.clone(stack[#stack])
		for k, v in changes do
			s[k] = v
		end
		table.insert(stack, s)
	end
	local i, n = 1, #text
	while i <= n do
		local lt = string.find(text, "<", i, true)
		if not lt then
			addCodepoints(items, decodeEntities(string.sub(text, i)), stack[#stack])
			break
		end
		addCodepoints(items, decodeEntities(string.sub(text, i, lt - 1)), stack[#stack])
		if string.sub(text, lt, lt + 3) == "<!--" then
			local e = string.find(text, "-->", lt + 4, true)
			i = if e then e + 3 else n + 1
			continue
		end
		local gt = string.find(text, ">", lt + 1, true)
		if not gt then
			addCodepoints(items, string.sub(text, lt), stack[#stack])
			break
		end
		local tag = string.sub(text, lt + 1, gt - 1)
		local closing = string.match(tag, "^%s*/") ~= nil
		local name = string.lower(string.match(tag, "^%s*/?%s*([%a]+)") or "")
		if name == "br" then
			table.insert(items, { cp = 10, s = stack[#stack] })
		elseif closing then
			if #stack > 1 then
				table.remove(stack)
			end
		elseif name == "b" then
			push({ bold = true })
		elseif name == "i" then
			push({ italic = true })
		elseif name == "u" then
			push({ underline = true })
		elseif name == "s" then
			push({ strike = true })
		elseif name == "uc" or name == "uppercase" or name == "sc" or name == "smallcaps" then
			push({ upper = true })
		elseif name == "font" then
			local a = attributes(tag)
			local changes = {}
			local r, g, b = parseColor(a.color)
			if r then
				changes.r, changes.g, changes.b = r, g, b
			end
			local size = tonumber(a.size)
			if size and size > 0 then
				changes.size = math.min(size, 200) * base.sizeMul
			end
			local t = tonumber(a.transparency)
			if t then
				changes.alpha = stack[#stack].alpha * (1 - math.clamp(t, 0, 1))
			end
			local weight = a.weight and string.lower(a.weight)
			if weight then
				local num = tonumber(weight)
				changes.bold = if num then num >= 600 else WEIGHTS[weight] == true
			end
			push(changes)
		elseif name == "stroke" then
			local a = attributes(tag)
			local r, g, b = parseColor(a.color)
			push({ stroke = {
				r = r or 0, g = g or 0, b = b or 0,
				thickness = tonumber(a.thickness) or 1,
				alpha = 1 - math.clamp(tonumber(a.transparency) or 0, 0, 1),
			} })
		elseif name == "mark" or name ~= "" then
			push({})
		end
		i = gt + 1
	end
	return items
end

local function itemGlyph(it)
	local f = getFont(it.s.bold, it.s.arial)
	return f, f.glyphs[it.cp] or f.glyphs[QUESTION]
end

local function itemK(it)
	return it.s.size * getFont(it.s.bold, it.s.arial).emPerTextSize / EM
end

local function itemAdvance(it, fx)
	local _, g = itemGlyph(it)
	return g[1] * itemK(it) * fx
end

local function layoutItems(items, fx, wrapW, baseSize)
	local lines = {}
	local function line(list)
		local width, size = 0, 0
		for _, it in list do
			width += itemAdvance(it, fx)
			size = math.max(size, it.s.size)
		end
		table.insert(lines, { items = list, width = width, size = if size > 0 then size else baseSize })
	end
	local para = {}
	local function flush()
		if not wrapW or #para == 0 then
			line(para)
			para = {}
			return
		end
		local a, n = 1, #para
		while a <= n do
			local width, lastSpace, j = 0, nil, a
			while j <= n do
				local adv = itemAdvance(para[j], fx)
				if width + adv > wrapW and j > a then
					break
				end
				width += adv
				if para[j].cp == 32 then
					lastSpace = j
				end
				j += 1
			end
			if j > n then
				line(table.move(para, a, n, 1, {}))
				break
			end
			local cut = if lastSpace and lastSpace > a then lastSpace else j - 1
			local e = cut
			while e > a and para[e].cp == 32 do
				e -= 1
			end
			line(table.move(para, a, e, 1, {}))
			a = cut + 1
			while a <= n and para[a].cp == 32 do
				a += 1
			end
		end
		para = {}
	end
	for _, it in items do
		if it.cp == 10 then
			flush()
		else
			table.insert(para, it)
		end
	end
	flush()
	return lines
end

local function linesHeight(lines, lineHeight)
	local h = 0
	for i, l in lines do
		h += if i < #lines then l.size * lineHeight else l.size
	end
	return h
end

local function truncateLine(l, fx, maxW, splitWord)
	local list = l.items
	if #list == 0 then
		return
	end
	local style = list[#list].s
	local f = getFont(style.bold, style.arial)
	local dots =if f.glyphs[ELLIPSIS] then { { cp = ELLIPSIS, s = style } }
		else { { cp = 46, s = style }, { cp = 46, s = style }, { cp = 46, s = style } }
	local dotsW = 0
	for _, it in dots do
		dotsW += itemAdvance(it, fx)
	end
	local width = l.width
	local n = #list
	while n > 0 and width + dotsW > maxW do
		width -= itemAdvance(list[n], fx)
		n -= 1
	end
	if splitWord then
		local m = n
		while m > 0 and list[m].cp ~= 32 do
			m -= 1
		end
		if m > 0 then
			for i = n, m, -1 do
				width -= itemAdvance(list[i], fx)
			end
			n = m - 1
		end
	end
	while n > 0 and list[n].cp == 32 do
		width -= itemAdvance(list[n], fx)
		n -= 1
	end
	local out = table.move(list, 1, n, 1, {})
	for _, it in dots do
		table.insert(out, it)
	end
	l.items, l.width = out, width + dotsW
end

local function sizeConstraint(label)
	local c = label:FindFirstChildOfClass("UITextSizeConstraint")
	if c then
		return math.max(1, c.MinTextSize), math.max(1, c.MaxTextSize)
	end
	return 1, 100
end

function M.paint(root: Instance, opts)
	local w = opts.writer
	local W, H = opts.width, opts.height
	local originX, originY = opts.origin.X, opts.origin.Y
	local full = { 0, 0, W, H }
	local currentClip = full

	local function setClip(clip)
		if clip ~= currentClip then
			w:put(R.CLIP, clip[1], clip[2], clip[3], clip[4])
			currentClip = clip
		end
	end

	local function emit(geom, lx0, ly0, lx1, ly1, cover, paint, grad)
		w:put(R.SHAPE, geom.x, geom.y, geom.w, geom.h, geom.rot, geom.cos, geom.sin, lx0, ly0, lx1, ly1)
		w:putList(cover)
		w:putList(paint)
		w:putList(grad)
	end

	local function geomOf(obj)
		local pos, size = obj.AbsolutePosition, obj.AbsoluteSize
		local rot = math.rad(obj.AbsoluteRotation)
		return { x = pos.X - originX, y = pos.Y - originY, w = size.X, h = size.Y, rot = rot, cos = math.cos(rot), sin = math.sin(rot) }
	end

	local function atlasId(f)
		return w:texture(f.pixels, ATLAS_W, f.height, 1)
	end

	local function drawText(geom, label, groupAlpha, grad, stroke, scale)
		local text, textColor = label.Text, label.TextColor3
		if label:IsA("TextBox") and text == "" then
			text, textColor = label.PlaceholderText, label.PlaceholderColor3
		end
		local textAlpha = (1 - label.TextTransparency) * groupAlpha
		if text == "" or textAlpha <= 0 then
			return
		end
		local pl, pt, pr, pb = scaledPadding(label, geom.w, geom.h, scale)
		local bx0, by0, bx1, by1 = pl, pt, geom.w - pr, geom.h - pb
		local boxW, boxH = math.max(0, bx1 - bx0), math.max(0, by1 - by0)
		local wrap = label.TextWrapped or label.TextScaled
		local bold = isBold(label)
		local arial, mul = arialFamily(label)
		local function itemsAt(size)
			local base = { r = textColor.R, g = textColor.G, b = textColor.B, alpha = 1, size = size, bold = bold,
				arial = arial, sizeMul = mul, italic = false, underline = false, strike = false, upper = false, stroke = nil }
			if label.RichText then
				return richItems(text, base)
			end
			local items = {}
			addCodepoints(items, text, base)
			return items
		end
		local function stretch(items, size)
			local plain = {}
			local ours = 0
			for _, it in items do
				local cp = if it.cp == 10 then 32 else it.cp
				table.insert(plain, utf8.char(cp))
				local glyphs = getFont(it.s.bold, it.s.arial).glyphs
				ours += (glyphs[cp] or glyphs[QUESTION])[1] * itemK(it)
			end
			local real = measureReal(table.concat(plain), size, label)
			return if real and ours > 0 then math.clamp(real / ours, 0.6, 1.6) else 1
		end

		local size = label.TextSize * scale * mul
		local items, fx, lines
		local lineHeight = label.LineHeight
		if label.TextScaled then
			local lo, hi = sizeConstraint(label)
			lo, hi = math.floor(lo * scale), math.floor(hi * scale)
			while lo < hi do
				local mid = (lo + hi + 1) // 2
				local its = itemsAt(mid * mul)
				local f2 = stretch(its, mid * mul)
				local ls = layoutItems(its, f2, boxW, mid * mul)
				local widest = 0
				for _, l in ls do
					widest = math.max(widest, l.width)
				end
				if widest <= boxW + 0.5 and linesHeight(ls, lineHeight) <= boxH + 0.5 then
					lo = mid
				else
					hi = mid - 1
				end
			end
			size = lo * mul
		end
		items = itemsAt(size)
		fx = stretch(items, size)
		lines = layoutItems(items, fx, if wrap and boxW > 0 then boxW else nil, size)

		local truncate = label.TextTruncate
		-- wrapped text keeps only the lines that fit, like TextBounds
		if truncate ~= Enum.TextTruncate.None or (label.TextWrapped and not label.TextScaled) then
			local split = truncate == Enum.TextTruncate.SplitWord
			local keep, h = 0, 0
			for i, l in lines do
				local lh = if i < #lines then l.size * lineHeight else l.size
				if keep > 0 and h + l.size > boxH + 0.5 then
					break
				end
				h += lh
				keep = i
			end
			local cut = keep < #lines
			for i = #lines, keep + 1, -1 do
				table.remove(lines, i)
			end
			local last = lines[#lines]
			if last and truncate ~= Enum.TextTruncate.None and (cut or last.width > boxW + 0.5) then
				truncateLine(last, fx, boxW, split)
			end
		end

		local height = linesHeight(lines, lineHeight)
		local yAlign = label.TextYAlignment
		local top = if yAlign == Enum.TextYAlignment.Top then by0
			elseif yAlign == Enum.TextYAlignment.Bottom then by1 - height
			else by0 + (boxH - height) / 2
		local xAlign = label.TextXAlignment
		local regular = getFont(false, arial)

		local strokeT, sr, sg, sb, sa = 0, 0, 0, 0, 0
		if stroke then
			strokeT = stroke.Thickness * scale
			sr, sg, sb = stroke.Color.R, stroke.Color.G, stroke.Color.B
			sa = (1 - stroke.Transparency) * groupAlpha
		elseif label.TextStrokeTransparency < 1 then
			strokeT = scale
			local c = label.TextStrokeColor3
			sr, sg, sb = c.R, c.G, c.B
			sa = (1 - label.TextStrokeTransparency) * groupAlpha
		end

		local maxGraphemes = label.MaxVisibleGraphemes
		local strokePass, fillPass, rules = {}, {}, {}
		local shown = 0
		local y = top
		for li, l in lines do
			local k0 = l.size * regular.emPerTextSize / EM
			local baseOff = (l.size - (regular.ascender - regular.descender) * k0) / 2 + regular.ascender * k0
			local baseline = y + baseOff
			local x = if xAlign == Enum.TextXAlignment.Left then bx0
				elseif xAlign == Enum.TextXAlignment.Right then bx1 - l.width
				else bx0 + (boxW - l.width) / 2
			local ruleStart, ruleStyle = nil, nil
			-- the real font's width comes mostly from spacing: stretched glyphs look wrong
			local glyphStretch = math.clamp(fx, 0.92, 1.06)
			for _, it in l.items do
				local f, g = itemGlyph(it)
				local k = itemK(it)
				local kx = k * glyphStretch
				local cell = g[1] * k * fx
				shown += 1
				local visible = maxGraphemes < 0 or shown <= maxGraphemes
				local st = it.s
				if visible and g[4] > 0 then
					local qx, qy = x + g[6] * kx + (cell - g[1] * kx) / 2, baseline + g[7] * k
					local shear = if st.italic then ITALIC_SHEAR else 0
					local quad = { f, g, qx, qy, k, kx, shear, baseline }
					local alpha = textAlpha * st.alpha
					table.insert(fillPass, { quad, st.r, st.g, st.b, alpha, 0 })
					local glyphStroke = st.stroke
					if glyphStroke then
						table.insert(strokePass, { quad, glyphStroke.r, glyphStroke.g, glyphStroke.b, alpha * glyphStroke.alpha, glyphStroke.thickness * scale })
					elseif strokeT > 0 and sa > 0 then
						table.insert(strokePass, { quad, sr, sg, sb, sa * st.alpha, strokeT })
					end
				end
				local adv = cell
				local rule = visible and (st.underline or st.strike)
				if rule and ruleStyle ~= st then
					if ruleStart then
						table.insert(rules, { ruleStart, x, baseline, ruleStyle })
					end
					ruleStart, ruleStyle = x, st
				elseif not rule and ruleStart then
					table.insert(rules, { ruleStart, x, baseline, ruleStyle })
					ruleStart, ruleStyle = nil, nil
				end
				x += adv
			end
			if ruleStart then
				table.insert(rules, { ruleStart, x, baseline, ruleStyle })
			end
			y += if li < #lines then l.size * lineHeight else l.size
		end

		local function emitGlyph(entry)
			local quad = entry[1]
			local f, g, qx, qy, k, kx, shear, baseline = quad[1], quad[2], quad[3], quad[4], quad[5], quad[6], quad[7], quad[8]
			local extra = math.min(entry[6], SPREAD * math.min(k, kx) - 0.5)
			if entry[6] > 0 and extra <= 0 then
				return
			end
			local distScale = math.min(k, kx) * 2 * SPREAD / 255
			local gw, gh = g[4] * kx, g[5] * k
			local lean = shear * gh
			emit(geom, qx, qy, qx + gw + lean, qy + gh,
				{ R.GLYPH, atlasId(f), g[2], g[3], g[4], g[5], qx, qy, k, kx, distScale, extra, shear, baseline },
				{ R.SOLID, entry[2], entry[3], entry[4], entry[5] }, grad)
		end
		for _, entry in strokePass do
			emitGlyph(entry)
		end
		for _, entry in fillPass do
			emitGlyph(entry)
		end
		for _, r in rules do
			local st = r[4]
			local t = math.max(1, st.size / 16)
			local alpha = textAlpha * st.alpha
			if st.underline then
				local ry = r[3] + st.size * 0.12
				emit(geom, r[1], ry, r[2], ry + t, COVER_FULL, { R.SOLID, st.r, st.g, st.b, alpha }, grad)
			end
			if st.strike then
				local ry = r[3] - st.size * 0.3
				emit(geom, r[1], ry, r[2], ry + t, COVER_FULL, { R.SOLID, st.r, st.g, st.b, alpha }, grad)
			end
		end
	end

	local function drawImage(geom, obj, img, radii, groupAlpha, grad)
		local iw, ih = img.Size.X, img.Size.Y
		local rx, ry, rw, rh = 0, 0, iw, ih
		local isViewport = obj:IsA("ViewportFrame")
		local tint, alpha, scaleType = Color3.new(1, 1, 1), groupAlpha, Enum.ScaleType.Stretch
		if not isViewport then
			local rectSize = obj.ImageRectSize
			if rectSize.X > 0 and rectSize.Y > 0 then
				local off = obj.ImageRectOffset
				rx, ry = math.clamp(math.floor(off.X), 0, iw - 1), math.clamp(math.floor(off.Y), 0, ih - 1)
				rw, rh = math.max(1, math.min(math.floor(rectSize.X), iw - rx)), math.max(1, math.min(math.floor(rectSize.Y), ih - ry))
			end
			tint, alpha, scaleType = obj.ImageColor3, (1 - obj.ImageTransparency) * groupAlpha, obj.ScaleType
		end
		if alpha <= 0 then
			return
		end
		local gw, gh = geom.w, geom.h
		local dx0, dy0, dw, dh = 0, 0, gw, gh
		if scaleType == Enum.ScaleType.Fit or scaleType == Enum.ScaleType.Crop then
			local sc = if scaleType == Enum.ScaleType.Fit then math.min(gw / rw, gh / rh) else math.max(gw / rw, gh / rh)
			dw, dh = rw * sc, rh * sc
			dx0, dy0 = (gw - dw) / 2, (gh - dh) / 2
		end
		local mode, tileW, tileH = R.MODE_STRETCH, 1, 1
		if scaleType == Enum.ScaleType.Tile then
			local ts = obj.TileSize
			mode = R.MODE_TILE
			tileW = math.max(1, ts.X.Scale * gw + ts.X.Offset)
			tileH = math.max(1, ts.Y.Scale * gh + ts.Y.Offset)
		end
		local sl, st, sr, sb, ss = 0, 0, 0, 0, 1
		if scaleType == Enum.ScaleType.Slice then
			mode = R.MODE_SLICE
			local c = obj.SliceCenter
			sl, st = math.max(0, c.Min.X - rx), math.max(0, c.Min.Y - ry)
			sr, sb = math.max(0, rw - (c.Max.X - rx)), math.max(0, rh - (c.Max.Y - ry))
			ss = math.max(obj.SliceScale, 1e-3)
		end
		if dw <= 0 or dh <= 0 then
			return
		end
		local pixelated = not isViewport and obj.ResampleMode == Enum.ResamplerMode.Pixelated
		local tl, tr, bl, br = radii[1], radii[2], radii[3], radii[4]
		local cover = if tl > 0 or tr > 0 or bl > 0 or br > 0 then { R.RRECT, 0, 0, gw, gh, tl, tr, bl, br } else COVER_FULL
		emit(geom, math.max(0, dx0), math.max(0, dy0), math.min(gw, dx0 + dw), math.min(gh, dy0 + dh), cover,
			{ R.IMAGE, w:texture(img.imageBuffer, iw, ih, 4), rx, ry, rw, rh, mode, dx0, dy0, dw, dh, tileW, tileH,
				sl, st, sr, sb, ss, if pixelated then 1 else 0, tint.R, tint.G, tint.B, alpha }, grad)
	end

	local function drawObject(obj: GuiObject, clip, groupAlpha)
		local geom = geomOf(obj)
		local gw, gh = geom.w, geom.h
		if gw <= 0 or gh <= 0 then
			return
		end
		setClip(clip)
		local scale = uiScaleOf(obj, root)
		local tl, tr, bl, br = cornerRadii(obj, gw, gh, scale)
		local rounded = tl > 0 or tr > 0 or bl > 0 or br > 0
		local grad = gradientList(obj, gw, gh)

		local shadow = childOf(obj, "UIShadow")
		if shadow and shadow.Enabled then
			local sa = (1 - shadow.Transparency) * groupAlpha
			if sa > 0 then
				local off, spread = shadow.Offset, shadow.Spread
				local ox, oy = off.X.Scale * gw + off.X.Offset * scale, off.Y.Scale * gh + off.Y.Offset * scale
				local sx, sy = spread.X.Scale * gw + spread.X.Offset * scale, spread.Y.Scale * gh + spread.Y.Offset * scale
				local blur = math.max(0, shadow.BlurRadius.Scale * math.min(gw, gh) + shadow.BlurRadius.Offset * scale)
				local x0, y0, x1, y1 = ox - sx, oy - sy, gw + ox + sx, gh + oy + sy
				local pad = blur + 1
				emit(geom, x0 - pad, y0 - pad, x1 + pad, y1 + pad, { R.SHADOW, x0, y0, x1, y1, tl, tr, bl, br, blur },
					solid(shadow.Color, sa), GRAD_NONE)
			end
		end

		local bgAlpha = (1 - obj.BackgroundTransparency) * groupAlpha
		if bgAlpha > 0 then
			emit(geom, 0, 0, gw, gh, if rounded then { R.RRECT, 0, 0, gw, gh, tl, tr, bl, br } else COVER_FULL,
				solid(obj.BackgroundColor3, bgAlpha), grad)
			local border = obj.BorderSizePixel * scale
			if border > 0 and not rounded then
				local mode = obj.BorderMode
				local o = if mode == Enum.BorderMode.Outline then border elseif mode == Enum.BorderMode.Middle then border / 2 else 0
				emit(geom, -o, -o, gw + o, gh + o, { R.RING, 0, 0, gw, gh, 0, 0, 0, 0, o, border - o, R.JOIN_MITER },
					solid(obj.BorderColor3, bgAlpha), GRAD_NONE)
			end
		end

		local img = opts.imageFor(obj, gw, gh)
		if img then
			drawImage(geom, obj, img, { tl, tr, bl, br }, groupAlpha, grad)
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
			drawText(geom, obj, groupAlpha, grad, textStroke, scale)
		end

		for _, stroke in borderStrokes do
			local t = stroke.Thickness * scale
			local okMode, sizing = pcall(function()
				return stroke.StrokeSizingMode
			end)
			if okMode and sizing == Enum.StrokeSizingMode.ScaledSize then
				t = stroke.Thickness * math.min(gw, gh)
			end
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
			pcall(function()
				local bo = stroke.BorderOffset
				local shift = bo.Scale * math.min(gw, gh) + bo.Offset * scale
				o, i = o + shift, i - shift
			end)
			local join = R.JOIN_ROUND
			local joinMode = stroke.LineJoinMode
			if joinMode == Enum.LineJoinMode.Miter then
				join = R.JOIN_MITER
			elseif joinMode == Enum.LineJoinMode.Bevel then
				join = R.JOIN_BEVEL
			end
			local reach = math.max(o, 0) + 1
			emit(geom, -reach, -reach, gw + reach, gh + reach, { R.RING, 0, 0, gw, gh, tl, tr, bl, br, o, i, join },
				solid(stroke.Color, sa), gradientList(stroke, gw, gh))
		end
	end

	local function drawPath(path, parent, clip, groupAlpha)
		if not parent:IsA("GuiObject") then
			return
		end
		-- Transparency needs RobloxScript to read
		local okT, transparency = pcall(function()
			return path.Transparency
		end)
		local alpha = (1 - (if okT then transparency else 0)) * groupAlpha
		local ok, points = pcall(path.GetControlPoints, path)
		if not ok or alpha <= 0 or #points < 2 then
			return
		end
		local geom = geomOf(parent)
		local scale = uiScaleOf(parent, root)
		local pw, ph = geom.w, geom.h
		local function px(u: UDim2)
			return u.X.Scale * pw + u.X.Offset * scale, u.Y.Scale * ph + u.Y.Offset * scale
		end
		local pts = {}
		local function add(x, y)
			local n = #pts
			if n >= 2 and pts[n - 1] == x and pts[n] == y then
				return
			end
			table.insert(pts, x)
			table.insert(pts, y)
		end
		local count = #points
		local segments = if path.Closed then count else count - 1
		for s = 1, segments do
			local a, b = points[s], points[s % count + 1]
			local x0, y0 = px(a.Position)
			local x3, y3 = px(b.Position)
			local rx, ry = px(a.RightTangent)
			local lx, ly = px(b.LeftTangent)
			local x1, y1, x2, y2 = x0 + rx, y0 + ry, x3 + lx, y3 + ly
			for step = 0, PATH_STEPS do
				local t = step / PATH_STEPS
				local u = 1 - t
				local b0, b1, b2, b3 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
				add(b0 * x0 + b1 * x1 + b2 * x2 + b3 * x3, b0 * y0 + b1 * y1 + b2 * y2 + b3 * y3)
			end
		end
		local n = #pts // 2
		if n < 2 or n > 4096 then
			return
		end
		local half = path.Thickness * scale / 2
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		for i = 1, n do
			minX, maxX = math.min(minX, pts[i * 2 - 1]), math.max(maxX, pts[i * 2 - 1])
			minY, maxY = math.min(minY, pts[i * 2]), math.max(maxY, pts[i * 2])
		end
		setClip(clip)
		local cover = { R.PATH, half, n }
		table.move(pts, 1, #pts, 4, cover)
		local reach = half + 1
		emit(geom, minX - reach, minY - reach, maxX + reach, maxY + reach, cover, solid(path.Color3, alpha), GRAD_NONE)
	end

	local function drawScrollbars(frame: ScrollingFrame, clip, groupAlpha)
		local alpha = (1 - frame.ScrollBarImageTransparency) * groupAlpha
		local t = frame.ScrollBarThickness
		if alpha <= 0 or t <= 0 or not frame.ScrollingEnabled then
			return
		end
		local geom = geomOf(frame)
		local canvas, window = frame.AbsoluteCanvasSize, frame.AbsoluteWindowSize
		local pos = frame.CanvasPosition
		-- the colour tints Roblox's dark grey scrollbar image
		local tint = frame.ScrollBarImageColor3
		local color = Color3.new(tint.R * 0.3, tint.G * 0.3, tint.B * 0.3)
		local dir = frame.ScrollingDirection
		setClip(clip)
		if canvas.Y > geom.h + 0.5 and dir ~= Enum.ScrollingDirection.X then
			local track = window.Y
			local thumb = math.max(t, track * window.Y / canvas.Y)
			local maxPos = canvas.Y - window.Y
			local y = (track - thumb) * math.clamp(pos.Y / maxPos, 0, 1)
			local left = frame.VerticalScrollBarPosition == Enum.VerticalScrollBarPosition.Left
			local x = if left then 0 else geom.w - t
			local r = t / 2
			emit(geom, x, y, x + t, y + thumb, { R.RRECT, x, y, x + t, y + thumb, r, r, r, r }, solid(color, alpha), GRAD_NONE)
		end
		if canvas.X > geom.w + 0.5 and dir ~= Enum.ScrollingDirection.Y then
			local track = window.X
			local thumb = math.max(t, track * window.X / canvas.X)
			local maxPos = canvas.X - window.X
			local x = (track - thumb) * math.clamp(pos.X / maxPos, 0, 1)
			local y = geom.h - t
			local r = t / 2
			emit(geom, x, y, x + thumb, y + t, { R.RRECT, x, y, x + thumb, y + t, r, r, r, r }, solid(color, alpha), GRAD_NONE)
		end
	end

	local function childClip(obj, clip)
		if obj:IsA("GuiObject") and (obj.ClipsDescendants or obj:IsA("ScrollingFrame") or obj:IsA("CanvasGroup")) and obj.AbsoluteRotation == 0 then
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

	-- Folders are see-through: their GuiObjects draw as children of the folder's parent.
	-- Path2Ds sort with the GuiObjects by ZIndex.
	local function sortedChildren(obj)
		local list = {}
		local n = 0
		local function add(parent)
			for _, c in parent:GetChildren() do
				if c:IsA("GuiObject") or c:IsA("Path2D") then
					n += 1
					table.insert(list, { c, n, parent })
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

	local function guiParent(entry, fallback)
		local p = entry[3]
		while p and not p:IsA("GuiObject") and p ~= root do
			p = p.Parent
		end
		return p or fallback
	end

	local walk, drawGlobal

	local function drawGroup(group, clip, groupAlpha, global)
		setClip(clip)
		w:put(R.LAYER)
		if global then
			drawGlobal(group, clip, true)
		else
			drawObject(group, clip, 1)
			walk(group, childClip(group, clip), 1)
		end
		setClip(full)
		local tint = group.GroupColor3
		w:put(R.COMPOSITE, (1 - group.GroupTransparency) * groupAlpha, tint.R, tint.G, tint.B)
	end

	walk = function(obj, clip, groupAlpha)
		for _, entry in sortedChildren(obj) do
			local c = entry[1]
			if not c.Visible then
				continue
			end
			if c:IsA("Path2D") then
				drawPath(c, guiParent(entry, obj), clip, groupAlpha)
			elseif c:IsA("CanvasGroup") then
				drawGroup(c, clip, groupAlpha, false)
				opts.yield()
			else
				drawObject(c, clip, groupAlpha)
				opts.yield()
				walk(c, childClip(c, clip), groupAlpha)
				if c:IsA("ScrollingFrame") then
					drawScrollbars(c, clip, groupAlpha)
				end
			end
		end
	end

	-- Global ZIndexBehavior: everything under base sorts by ZIndex together; a CanvasGroup
	-- sorts as one item and its contents sort inside its layer.
	drawGlobal = function(base, clip, includeBase)
		local all = {}
		local function collect(obj, c0, groupAlpha)
			for _, entry in sortedChildren(obj) do
				local c = entry[1]
				if c.Visible then
					table.insert(all, { c, c0, groupAlpha, #all, entry })
					if c:IsA("GuiObject") and not c:IsA("CanvasGroup") then
						collect(c, childClip(c, c0), groupAlpha)
					end
				end
			end
		end
		if includeBase and base:IsA("GuiObject") then
			table.insert(all, { base, clip, 1, 0, nil, true })
			collect(base, childClip(base, clip), 1)
		else
			collect(base, clip, 1)
		end
		table.sort(all, function(a, b)
			if a[6] ~= b[6] then
				return a[6] == true
			end
			if a[1].ZIndex ~= b[1].ZIndex then
				return a[1].ZIndex < b[1].ZIndex
			end
			return a[4] < b[4]
		end)
		-- scrollbars go over their frame's contents, which sort separately here
		local bars = {}
		for _, e in all do
			local c = e[1]
			if c:IsA("Path2D") then
				drawPath(c, guiParent(e[5], base), e[2], e[3])
			elseif c:IsA("CanvasGroup") and not e[6] then
				drawGroup(c, e[2], e[3], true)
			else
				drawObject(c, e[2], e[3])
				if c:IsA("ScrollingFrame") then
					table.insert(bars, e)
				end
			end
			opts.yield()
		end
		for _, e in bars do
			drawScrollbars(e[1], e[2], e[3])
		end
	end

	if opts.global then
		if root:IsA("GuiObject") and not root.Visible then
			return
		end
		if root:IsA("CanvasGroup") then
			drawGroup(root, full, 1, true)
		else
			drawGlobal(root, full, true)
		end
	else
		if root:IsA("GuiObject") then
			if root.Visible then
				if root:IsA("CanvasGroup") then
					drawGroup(root, full, 1, false)
				else
					drawObject(root, full, 1)
					walk(root, childClip(root, full), 1)
					if root:IsA("ScrollingFrame") then
						drawScrollbars(root, full, 1)
					end
				end
			end
		else
			walk(root, full, 1)
		end
	end
end

return M
