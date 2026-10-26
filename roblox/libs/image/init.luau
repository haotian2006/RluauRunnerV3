local Image = require(script.image)
local pngEncoder = require(script.pngEncoder)
local gifEncoder = require(script.gifEncoder)
local plotfunction = require(script.plotFunction)
local decoder = require(script.pngDecoder)
local render3d = require(script.render3d)
local render2d = require(script.render2d)
local raster = require(script.raster)
local styles = require(script.styles)
local nativeImage = require(script.native)
local function empty()end

local HttpService = game:GetService("HttpService")

local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local MAX_DOWNLOAD = 8 * 1024 * 1024
local MAX_SIDE = 1024

-- PNG bytes always start with the signature, so a leading scheme is unambiguous.
local function isUrl(str: string): boolean
	return string.match(str, "^https?://") ~= nil
end

local function fetch(url: string): string
	local ok, res = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
	if not ok then
		error(`fromPng: request failed: {res}`, 3)
	end
	if not res.Success then
		error(`fromPng: HTTP {res.StatusCode} {res.StatusMessage}`, 3)
	end
	if #res.Body > MAX_DOWNLOAD then
		error(`fromPng: {#res.Body} bytes exceeds the {MAX_DOWNLOAD} byte limit`, 3)
	end
	return res.Body
end

-- Checked before decoding: the decoder sizes its buffer straight from IHDR, so a
-- remote file could otherwise ask for an arbitrarily large allocation.
local function checkHeader(str: string)
	if #str < 24 or string.sub(str, 1, 8) ~= PNG_SIGNATURE then
		error("fromPng: data is not a PNG", 3)
	end
	local width = string.unpack(">I4", str, 17)
	local height = string.unpack(">I4", str, 21)
	if width < 1 or height < 1 or width > MAX_SIDE or height > MAX_SIDE then
		error(`fromPng: {width}x{height} is outside the 1x1..{MAX_SIDE}x{MAX_SIDE} range`, 3)
	end
end

-- Encoders size their buffers from Size and read imageBuffer up to it.
local function checkImage(image, who: string, size: Vector2?)
	local s = type(image) == "table" and image.Size
	if typeof(s) ~= "Vector2" or typeof(image.imageBuffer) ~= "buffer" then
		error(`{who}: expected an Image`, 3)
	end
	local w, h = s.X, s.Y
	if w < 1 or h < 1 or w > MAX_SIDE or h > MAX_SIDE or w % 1 ~= 0 or h % 1 ~= 0 then
		error(`{who}: {w}x{h} is outside the 1x1..{MAX_SIDE}x{MAX_SIDE} range`, 3)
	end
	if size and s ~= size then
		error(`{who}: every frame must be {size.X}x{size.Y}`, 3)
	end
	if buffer.len(image.imageBuffer) < w * h * 4 then
		error(`{who}: imageBuffer is smaller than Size`, 3)
	end
end

local function parseAssetId(v): string?
	if type(v) == "number" then
		return if v >= 1 and v < 2 ^ 53 and v == math.floor(v) then string.format("%d", v) else nil
	elseif type(v) == "string" then
		return string.match(v, "^%s*(%d+)%s*$")
			or string.match(v, "^rbxassetid://(%d+)$")
			or string.match(v, "roblox%.com/asset/?%?id=(%d+)")
	end
	return nil
end

-- Direction light travels, like ViewportFrame.LightDirection.
local DEFAULT_LIGHT = Vector3.new(-0.35, -0.85, -0.4)
local CORNERS = {}
for _, x in { -1, 1 } do
	for _, y in { -1, 1 } do
		for _, z in { -1, 1 } do
			table.insert(CORNERS, Vector3.new(x, y, z))
		end
	end
end

local function readCamera(cam)
	local ok, cf, fov = pcall(function()
		return cam.CFrame, cam.FieldOfView
	end)
	if ok and typeof(cf) == "CFrame" and type(fov) == "number" then
		return cf, fov
	end
	return nil
end

local function fitCamera(target, parts, fov, aspect)
	local pts = {}
	for _, p in parts do
		local cf, half = p.CFrame, p.Size / 2
		for _, c in CORNERS do
			table.insert(pts, cf * (half * c))
		end
	end
	if #pts == 0 then
		return CFrame.lookAt(Vector3.new(0, 0, 10), Vector3.zero)
	end
	local lo, hi = pts[1], pts[1]
	for _, p in pts do
		lo, hi = lo:Min(p), hi:Max(p)
	end
	local center = (lo + hi) / 2
	-- face the root's front, but only turn around Y: a tilted pivot (an upright cylinder) would roll
	-- the view. WorldRoot is a Model too, and its pivot means nothing here.
	local function yaw(cf)
		local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		return if look.Magnitude < 1e-3 then CFrame.identity else CFrame.lookAt(Vector3.zero, look.Unit)
	end
	local rot = if target:IsA("WorldRoot") then CFrame.identity
		elseif target:IsA("Model") then yaw(target:GetPivot())
		elseif target:IsA("BasePart") then yaw(target.CFrame)
		else CFrame.identity
	local toCam = rot:VectorToWorldSpace(Vector3.new(0.55, 0.45, -1).Unit)
	local view = CFrame.lookAt(Vector3.zero, -toCam, rot.UpVector)
	local right, up, fwd = view.RightVector, view.UpVector, view.LookVector

	local minR, maxR, minU, maxU = math.huge, -math.huge, math.huge, -math.huge
	for _, p in pts do
		local d = p - center
		local r, u = d:Dot(right), d:Dot(up)
		minR, maxR = math.min(minR, r), math.max(maxR, r)
		minU, maxU = math.min(minU, u), math.max(maxU, u)
	end
	center += right * ((minR + maxR) / 2) + up * ((minU + maxU) / 2)

	local tanV = math.tan(fov / 2)
	local tanH = tanV * aspect
	local dist = 0
	for _, p in pts do
		local d = p - center
		local z = d:Dot(fwd)
		dist = math.max(dist, math.abs(d:Dot(right)) / tanH - z, math.abs(d:Dot(up)) / tanV - z)
	end
	dist = math.max(dist * 1.08, (hi - lo).Magnitude * 0.05 + 0.1)
	return CFrame.lookAt(center - fwd * dist, center, rot.UpVector)
end

local THUMB_SIZES = { 30, 42, 50, 75, 110, 140, 150, 250, 420, 512, 700 }

local function imageAssetId(obj): string?
	local id = obj.Image
	if id == "" then
		local ok, content = pcall(function()
			return obj.ImageContent
		end)
		if ok and content and content.Uri then
			id = content.Uri
		end
	end
	return parseAssetId(id) or string.match(id, "^rbxthumb://.-id=(%d+)")
end

return function(println,io,fetchAsset,sandbox)
	local Image = {
		new = Image,
		fromPng = function(str:string,shouldLog)
			if isUrl(str) then
				local line = shouldLog and println(`PNG: Downloading {str}...`) or nil
				str = fetch(str)
				if line then
					println(`PNG: Downloaded {#str} bytes`, line)
				end
			end
			checkHeader(str)
			local buf,vec = decoder(str, shouldLog and println or empty)
			local img = Image(vec)
			img.imageBuffer = buf
			return img
		end,
		toPng = function(image,shouldLog,timmeout)
			checkImage(image, "toPng")
			local encoded = nativeImage.png(image)
			if encoded then
				if shouldLog then
					println(`PNG: Encoded {#encoded} bytes`)
				end
				return encoded
			end
			return pngEncoder(image, shouldLog and println or empty,timmeout)
		end,
		toGif = function(frames,durations,options,shouldLog)
			if type(frames) ~= "table" or #frames < 1 then
				error("toGif: expected a list of Images", 2)
			end
			checkImage(frames[1], "toGif")
			for _, frame in frames do
				checkImage(frame, "toGif", frames[1].Size)
			end
			local encoded = nativeImage.gif(frames, durations, options)
			if encoded then
				if shouldLog then
					println(`GIF: Encoded {#frames} frames, {#encoded} bytes`)
				end
				return encoded
			end
			return gifEncoder(frames,durations,options, shouldLog and println or empty)
		end,
	}
	Image.fromAsset = function(id, size: number?, shouldLog)
		local assetId = parseAssetId(id)
		if not assetId then
			error("fromAsset: arg 1 must be an asset id or rbxassetid:// string", 2)
		end
		if size ~= nil and (type(size) ~= "number" or size < 1) then
			error("fromAsset: arg 2 must be a positive number", 2)
		end
		if not fetchAsset then
			error("fromAsset: asset downloads aren't available here", 2)
		end
		size = size and math.min(math.floor(size), MAX_SIDE)
		local line = shouldLog and println(`PNG: Downloading asset {assetId}...`) or nil
		local ok, str = fetchAsset(assetId, size)
		if not ok then
			error(`fromAsset: {str}`, 2)
		end
		if line then
			println(`PNG: Downloaded {#str} bytes`, line)
		end
		checkHeader(str)
		local buf,vec = decoder(str, shouldLog and println or empty)
		local img = Image.new(vec)
		img.imageBuffer = buf
		local longest = math.max(vec.X, vec.Y)
		if size and longest ~= size then
			local scale = size / longest
			return img:Resize(Vector2.new(math.max(1, math.round(vec.X * scale)), math.max(1, math.round(vec.Y * scale))))
		end
		return img
	end
	local function renderTarget(v)
		if sandbox and sandbox.resolve then
			return sandbox.resolve(v)
		end
		return if typeof(v) == "Instance" then v else nil
	end

	-- AssetService's EditableImage is blocked on these servers, so the sandbox hands out Image-backed ones.
	-- Content.fromObject gives one a uri that rides on the ImageLabel (and clones) for the UI renderer.
	local EDITABLE_URI = "rbxtemp://luaurunner/editable/"
	local editables = {}
	local editableOf = setmetatable({}, { __mode = "k" })
	local editableCount = 0

	local function newEditable(img)
		editableCount += 1
		local st = { image = img, id = editableCount }
		local object = newproxy(true)
		local function alive(fn)
			if st.destroyed then
				error(`{fn}: this EditableImage was destroyed`, 3)
			end
			return st.image
		end
		local function source(v, fn)
			local other = editableOf[v]
			if other and not other.destroyed then
				return other.image
			elseif type(v) == "table" and v.imageBuffer then
				return v
			end
			error(`{fn}: expected an EditableImage, got {typeof(v)}`, 3)
		end
		local methods = {
			DrawRectangle = function(_, position, size, color, transparency, combineType)
				alive("DrawRectangle"):DrawRectangle(position, size, color, transparency, combineType)
			end,
			DrawCircle = function(_, center, radius, color, transparency, combineType)
				alive("DrawCircle"):DrawCircle(center, radius, color, transparency, combineType)
			end,
			DrawLine = function(_, p1, p2, color, transparency, combineType)
				alive("DrawLine"):DrawLine(p1, p2, color, transparency, combineType)
			end,
			ReadPixelsBuffer = function(_, position, size)
				return alive("ReadPixelsBuffer"):ReadPixelsBuffer(position, size)
			end,
			WritePixelsBuffer = function(_, position, size, pixels)
				alive("WritePixelsBuffer"):WritePixelsBuffer(position, size, pixels)
			end,
			DrawImage = function(_, position, image, combineType)
				alive("DrawImage"):DrawImageTransformed(position, Vector2.one, 0, source(image, "DrawImage"), {
					CombineType = combineType,
					PivotPoint = Vector2.zero,
				})
			end,
			DrawImageTransformed = function(_, position, scale, rotation, image, options)
				alive("DrawImageTransformed"):DrawImageTransformed(position, scale, rotation, source(image, "DrawImageTransformed"), options)
			end,
			DrawImageProjected = function()
				error("DrawImageProjected isn't supported here", 2)
			end,
			ReadPixels = function(_, position, size)
				local buf = alive("ReadPixels"):ReadPixelsBuffer(position, size)
				local out = table.create(buffer.len(buf))
				for i = 0, buffer.len(buf) - 1 do
					out[i + 1] = buffer.readu8(buf, i) / 255
				end
				return out
			end,
			WritePixels = function(_, position, size, pixels)
				local buf = buffer.create(#pixels)
				for i, v in pixels do
					buffer.writeu8(buf, i - 1, math.clamp(math.floor(v * 255 + 0.5), 0, 255))
				end
				alive("WritePixels"):WritePixelsBuffer(position, size, buf)
			end,
			Resize = function(_, size)
				st.image = alive("Resize"):Resize(size)
			end,
			Crop = function(_, minPoint, maxPoint)
				st.image = alive("Crop"):Crop(minPoint, maxPoint - minPoint)
			end,
			IsA = function(_, className)
				return className == "EditableImage" or className == "Object"
			end,
			Destroy = function()
				st.destroyed = true
				editables[st.id] = nil
			end,
		}
		local mt = getmetatable(object)
		mt.__index = function(_, k)
			if k == "Size" then
				return alive("Size").Size
			elseif k == "ClassName" then
				return "EditableImage"
			end
			local m = methods[k]
			if m then
				return m
			end
			error(`{k} is not a valid member of EditableImage`, 2)
		end
		mt.__newindex = function(_, k)
			error(`{k} cannot be assigned to on EditableImage`, 2)
		end
		mt.__tostring = function()
			return "EditableImage"
		end
		mt.__metatable = "The metatable is locked"
		editables[st.id] = st
		editableOf[object] = st
		return object
	end

	local function editableFromUri(uri)
		local id = type(uri) == "string" and string.match(uri, "^rbxtemp://luaurunner/editable/(%d+)$")
		local st = id and editables[tonumber(id)]
		return st and st.image
	end

	local function editableFor(obj)
		local ok, content = pcall(function()
			return obj.ImageContent
		end)
		return (ok and content and editableFromUri(content.Uri)) or editableFromUri(obj.Image)
	end

	Image._editable = {
		create = function(options)
			local size = Vector2.new(512, 512)
			if options ~= nil then
				if type(options) ~= "table" then
					error("CreateEditableImage: options must be a table", 3)
				end
				if options.Size ~= nil then
					if typeof(options.Size) ~= "Vector2" then
						error("CreateEditableImage: Size must be a Vector2", 3)
					end
					size = options.Size
				end
			end
			if size.X < 1 or size.Y < 1 or size.X > 1024 or size.Y > 1024 then
				error("CreateEditableImage: Size must be between 1x1 and 1024x1024", 3)
			end
			return newEditable(Image.new(size))
		end,
		load = function(content)
			local uri = if typeof(content) == "Content" then content.Uri else content
			local copy = editableFromUri(uri)
			if copy then
				return newEditable(copy:Clone())
			end
			local ok, img = pcall(Image.fromAsset, uri)
			if not ok then
				error(`CreateEditableImageAsync: {string.gsub(tostring(img), "^fromAsset: ", "")}`, 3)
			end
			return newEditable(img)
		end,
		uriOf = function(v)
			local st = editableOf[v]
			return if st then EDITABLE_URI .. st.id else nil
		end,
		imageOf = function(v)
			local st = editableOf[v]
			return if st and not st.destroyed then st.image else nil
		end,
	}

	local lastYield = os.clock()
	local function maybeYield()
		if os.clock() - lastYield > 0.05 then
			task.wait()
			lastYield = os.clock()
		end
	end

	local function partsUnder(target)
		local parts = {}
		if target:IsA("BasePart") and not target:IsA("Terrain") then
			table.insert(parts, target)
		end
		for _, d in target:GetDescendants() do
			if d:IsA("BasePart") and not d:IsA("Terrain") then
				table.insert(parts, d)
			end
		end
		return parts
	end

	local LIGHTING_PROPS = {
		"Ambient", "OutdoorAmbient", "Brightness", "ColorShift_Top", "ColorShift_Bottom", "EnvironmentDiffuseScale",
		"EnvironmentSpecularScale", "ExposureCompensation", "FogColor", "FogEnd", "FogStart", "GlobalShadows",
		"ShadowSoftness", "ClockTime",
	}

	local function readLighting()
		if sandbox and sandbox.lighting then
			local ok, info = pcall(sandbox.lighting)
			if ok and type(info) == "table" then
				return info
			end
		end
		local L = game:GetService("Lighting")
		local info = { children = L:GetChildren() }
		for _, k in LIGHTING_PROPS do
			local ok, v = pcall(function()
				return L[k]
			end)
			if ok then
				info[k] = v
			end
		end
		local okSun, sun = pcall(L.GetSunDirection, L)
		local okMoon, moon = pcall(L.GetMoonDirection, L)
		info.SunDirection = if okSun then sun else Vector3.new(-0.35, 0.85, 0.4).Unit
		info.MoonDirection = if okMoon then moon else -info.SunDirection
		return info
	end

	local function c3(c: Color3?, default: Vector3)
		return if typeof(c) == "Color3" then Vector3.new(c.R, c.G, c.B) else default
	end
	local function lerp3(a: Vector3, b: Vector3, t: number)
		return a + (b - a) * t
	end
	local function clamp01(x)
		return math.clamp(x, 0, 1)
	end

	local DAY_HORIZON, DAY_ZENITH, DAY_GROUND = Vector3.new(0.80, 0.88, 0.97), Vector3.new(0.22, 0.64, 0.86), Vector3.new(0.50, 0.53, 0.57)
	local AMBIENT_ZENITH = Vector3.new(0.40, 0.71, 0.87)
	local NIGHT_HORIZON, NIGHT_ZENITH, NIGHT_GROUND = Vector3.new(0.10, 0.12, 0.20), Vector3.new(0.02, 0.03, 0.08), Vector3.new(0.05, 0.05, 0.06)
	local SUNSET = Vector3.new(1.0, 0.55, 0.3)

	local function sceneLight(target, o)
		if target:IsA("ViewportFrame") then
			local a, l = target.Ambient, target.LightColor
			local ambient = Vector3.new(a.R, a.G, a.B)
			local toLight = -(o.lightDir or target.LightDirection).Unit
			return {
				toLight = toLight, sunDir = toLight, sun = Vector3.one, sunCos = 2,
				light = Vector3.new(l.R, l.G, l.B), ambient = ambient, skyAmbient = Vector3.zero, bounce = Vector3.zero,
				horizon = ambient, zenith = ambient, ground = ambient * 0.5, shadows = false,
			}
		end
		local info = readLighting()
		local sunDir = (info.SunDirection or Vector3.yAxis).Unit
		local moonDir = (info.MoonDirection or -sunDir).Unit
		-- Roblox keeps the sun at full strength until it is nearly down
		local day = clamp01((sunDir.Y + 0.02) / 0.1)
		local warm = clamp01(sunDir.Y / 0.15)
		local exposure = 2 ^ (info.ExposureCompensation or 0)
		local brightness = (0.38 + 0.19 * math.max(info.Brightness or 2, 0)) * exposure
		local sunColor = lerp3(SUNSET, Vector3.new(1, 0.97, 0.9), warm)
		local lightColor = lerp3(Vector3.new(0.5, 0.55, 0.7) * 0.25, sunColor, day) * brightness
			+ c3(info.ColorShift_Top, Vector3.zero) * brightness * day
		local toLight = if o.lightDir then -o.lightDir.Unit elseif day > 0 then sunDir else moonDir

		local horizon = lerp3(NIGHT_HORIZON, DAY_HORIZON, day)
		local zenith = lerp3(NIGHT_ZENITH, DAY_ZENITH * (0.85 + 0.15 * clamp01(sunDir.Y / 0.5)), day)
		local ground = lerp3(NIGHT_GROUND, DAY_GROUND, day)
		horizon = lerp3(horizon, SUNSET, (1 - warm) * day * 0.55)

		local atmosphere, sky
		for _, c in info.children or {} do
			if c:IsA("Atmosphere") then
				atmosphere = c
			elseif c:IsA("Sky") then
				sky = c
			end
		end
		local fog
		local horizonOffset, groundScale = 0, 4
		if atmosphere then
			local ac = c3(atmosphere.Color, Vector3.new(0.78, 0.78, 0.78))
			local decay = c3(atmosphere.Decay, Vector3.new(0.42, 0.44, 0.49))
			horizon = lerp3(horizon, ac * 1.08 * math.max(day, 0.15), 0.85 + 0.15 * clamp01(atmosphere.Haze / 10))
			local grey = (decay.X + decay.Y + decay.Z) / 3
			ground = lerp3(decay, Vector3.one * grey, 0.6) * 0.85 * math.max(day, 0.15)
			horizonOffset = math.clamp(atmosphere.Offset, 0, 1) * 0.8
			groundScale = 2.5
			local density = math.max(atmosphere.Density, 0)
			if density > 0 then
				fog = { start = 0, finish = 0, density = density * 0.004, color = horizon }
			end
		elseif info.FogEnd and info.FogEnd < 1e5 then
			fog = { start = info.FogStart or 0, finish = info.FogEnd, density = 0, color = c3(info.FogColor, horizon) }
		end

		local outdoor = c3(info.OutdoorAmbient, Vector3.new(0.5, 0.5, 0.5))
		local indoor = c3(info.Ambient, Vector3.zero)
		local ambient = (outdoor * 0.4 + indoor * 0.2) * exposure
		local diffuseScale = info.EnvironmentDiffuseScale or 0
		local skyTop = lerp3(NIGHT_ZENITH, AMBIENT_ZENITH, day)
		local skyAmbient = Vector3.new(skyTop.X ^ 3, skyTop.Y ^ 3.5, skyTop.Z ^ 1.5) * (0.25 + 0.3 * diffuseScale) * exposure
		local bounce = (lightColor * math.max(toLight.Y, 0) * 0.65 + skyAmbient * 0.5 + ambient) * 0.9
		local envSpecular = (0.2 + 0.5 * (info.EnvironmentSpecularScale or 0)) * math.max(day, 0.2)

		local sunCos = math.cos(math.rad(21) * 0.45)
		local celestial = true
		if sky then
			local okSize, size = pcall(function()
				return sky.SunAngularSize
			end)
			if okSize and type(size) == "number" then
				sunCos = math.cos(math.rad(math.max(size, 0.5)) * 0.45)
			end
			celestial = sky.CelestialBodiesShown
		end
		if not celestial or day <= 0 then
			sunCos = 2
		end
		return {
			toLight = toLight, sunDir = sunDir, sun = sunColor * 1.4, sunCos = sunCos,
			light = lightColor, ambient = ambient, skyAmbient = skyAmbient, bounce = bounce, envSpecular = envSpecular,
			horizon = horizon, zenith = zenith, ground = ground, fog = fog,
			horizonOffset = horizonOffset, groundScale = groundScale,
			shadows = info.GlobalShadows ~= false, softness = info.ShadowSoftness or 0.2,
		}
	end

	local function runCommands(w, width, height, color: buffer?, scale: number?)
		local s = scale or 1
		local out = color or buffer.create(width * height * 4)
		if nativeImage.raster(w, width * s, height * s, out, s) then
			return out
		end
		lastYield = os.clock()
		if s == 1 then
			raster.run(w.buf, w.n, width, height, out, w.textures, maybeYield)
			return out
		end
		local big = buffer.create(width * s * height * s * 4)
		if color then
			raster.upsample(out, width, height, s, big)
		end
		raster.run(w.buf, w.n, width * s, height * s, big, w.textures, maybeYield)
		raster.downsample(big, width, height, s, out, maybeYield)
		return out
	end

	local renderGui, decalImage, prefetchDecals, meshGeometry, meshTexture, prefetchMeshes

	-- o: camCF, fov (degrees), lightDir, background (nil = default, false = none, or a Color3)
	local function render3dInto(target, root, o, w, h)
		local camCF, fov = o.camCF, o.fov
		local background, backgroundAlpha
		if target:IsA("ViewportFrame") then
			if not camCF and target.CurrentCamera then
				local vcf, vfov = readCamera(target.CurrentCamera)
				camCF, fov = vcf, fov or vfov
			end
			background, backgroundAlpha = target.BackgroundColor3, 1 - target.BackgroundTransparency
		elseif target:IsA("WorldRoot") then
			if not camCF and root then
				local ok, wsCam = pcall(function()
					return root.CurrentCamera
				end)
				if ok and wsCam then
					local wcf, wfov = readCamera(wsCam)
					-- a camera nobody moved (the server default) frames the parts instead
					local untouched = wcf
						and (wcf.Position - Vector3.new(0, 20, 20)).Magnitude < 0.01
						and wcf.LookVector:Dot(Vector3.new(0, -1, -1).Unit) > 0.9999
						and wfov == 70
					if not untouched then
						camCF, fov = wcf, fov or wfov
					end
				end
			end
			background = "sky"
		end
		if o.background == false then
			background = nil
		elseif o.background ~= nil then
			background, backgroundAlpha = o.background, 1
		end
		local fovRad = math.rad(math.clamp(fov or (if camCF then 70 else 40), 1, 120))
		if not camCF then
			camCF = fitCamera(target, partsUnder(target), fovRad, w / h)
		end
		prefetchDecals(target)
		prefetchMeshes(target)
		local s = o.scale or 2
		local writer = raster.writer()
		render3d(writer, target, {
			width = w * s,
			height = h * s,
			scale = s,
			materials = o.materials,
			camera = camCF,
			fov = fovRad,
			background = background,
			backgroundAlpha = backgroundAlpha,
			light = sceneLight(target, o),
			imageFor = decalImage,
			meshGeometry = if nativeImage.readMesh then meshGeometry else nil,
			meshTexture = meshTexture,
			renderGui = function(gui, gw, gh)
				local ok, img = pcall(renderGui, gui, Vector2.new(gw, gh))
				return if ok then img else nil
			end,
		})
		return runCommands(writer, w, h, nil, s)
	end

	local function nearestCollector(inst)
		local cur = inst
		while cur do
			if cur:IsA("LayerCollector") then
				return cur
			end
			cur = cur.Parent
		end
		return nil
	end

	-- Text sizes its own AutomaticSize label in the engine only on clients, so the clone
	-- gets the measured size baked in, innermost labels first.
	local function sizeAutoText(root)
		local list = {}
		for _, d in root:GetDescendants() do
			if render2d.isTextObject(d) and d.AutomaticSize ~= Enum.AutomaticSize.None then
				table.insert(list, d)
			end
		end
		if render2d.isTextObject(root) and root.AutomaticSize ~= Enum.AutomaticSize.None then
			table.insert(list, root)
		end
		local depth = {}
		for _, l in list do
			local n, cur = 0, l
			while cur and cur ~= root do
				n += 1
				cur = cur.Parent
			end
			depth[l] = n
		end
		table.sort(list, function(a, b)
			return depth[a] > depth[b]
		end)
		for _, label in list do
			local abs = label.AbsoluteSize
			local pl, pt, pr, pb = render2d.paddingOf(label, abs.X, abs.Y)
			local auto = label.AutomaticSize
			local wrapW = if auto == Enum.AutomaticSize.Y then abs.X - pl - pr else nil
			local content = render2d.textSize(label, wrapW)
			local parent = label.Parent
			local parentSize = if parent and parent:IsA("GuiBase2d") then parent.AbsoluteSize else Vector2.zero
			local sz = label.Size
			local x, y = sz.X, sz.Y
			-- grow from the size the label has without AutomaticSize, which is what remains
			if auto ~= Enum.AutomaticSize.Y then
				local base = x.Scale * parentSize.X + x.Offset
				x = UDim.new(x.Scale, x.Offset + math.max(0, math.max(abs.X, content.X + pl + pr) - base))
			end
			if auto ~= Enum.AutomaticSize.X then
				local base = y.Scale * parentSize.Y + y.Offset
				y = UDim.new(y.Scale, y.Offset + math.max(0, math.max(abs.Y, content.Y + pt + pb) - base))
			end
			label.AutomaticSize = Enum.AutomaticSize.None
			label.Size = UDim2.new(x, y)
		end
	end

	local imageCache, imageCacheCount = {}, 0

	local function thumbSize(iw, ih)
		local want = math.max(iw, ih)
		for _, s in THUMB_SIZES do
			if s >= want then
				return s
			end
		end
		return THUMB_SIZES[#THUMB_SIZES]
	end

	local function loadImage(id, px)
		local key = id .. ":" .. px
		local img = false
		local ok, bytes = fetchAsset(id, px)
		if ok then
			local dok, buf, vec = pcall(function()
				checkHeader(bytes)
				return decoder(bytes, empty)
			end)
			if dok then
				img = Image.new(vec)
				img.imageBuffer = buf
			end
		end
		if imageCacheCount >= 64 then
			table.clear(imageCache)
			imageCacheCount = 0
		end
		imageCache[key] = img
		imageCacheCount += 1
	end

	local function prefetchImages(root)
		if not fetchAsset then
			return
		end
		local pending, started = 0, {}
		for _, d in root:GetDescendants() do
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				local id = imageAssetId(d)
				local abs = d.AbsoluteSize
				if id and abs.X > 0 and abs.Y > 0 then
					local px = thumbSize(abs.X, abs.Y)
					local key = id .. ":" .. px
					if imageCache[key] == nil and not started[key] then
						started[key] = true
						pending += 1
						task.spawn(function()
							pcall(loadImage, id, px)
							pending -= 1
						end)
					end
				end
			end
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
	end

	local function imageFor(obj, iw, ih)
		if obj:IsA("ViewportFrame") then
			local vw, vh = math.clamp(math.floor(iw + 0.5), 1, MAX_SIDE), math.clamp(math.floor(ih + 0.5), 1, MAX_SIDE)
			local ok, buf = pcall(render3dInto, obj, nil, { background = false }, vw, vh)
			if not ok then
				return nil
			end
			local img = Image.new(Vector2.new(vw, vh))
			img.imageBuffer = buf
			return img
		end
		if not (obj:IsA("ImageLabel") or obj:IsA("ImageButton")) then
			return nil
		end
		local editable = editableFor(obj)
		if editable then
			return editable
		end
		if not fetchAsset then
			return nil
		end
		local id = imageAssetId(obj)
		if not id then
			return nil
		end
		local key = id .. ":" .. thumbSize(iw, ih)
		if imageCache[key] == nil then
			pcall(loadImage, id, thumbSize(iw, ih))
		end
		return imageCache[key] or nil
	end

	local DECAL_SIZE = 420

	local function decalAssetId(decal): string?
		return parseAssetId(decal.Texture) or string.match(decal.Texture, "^rbxthumb://.-id=(%d+)")
	end

	decalImage = function(decal)
		local ok, content = pcall(function()
			return decal.TextureContent
		end)
		local editable = (ok and content and editableFromUri(content.Uri)) or editableFromUri(decal.Texture)
		if editable then
			return editable
		end
		local id = fetchAsset and decalAssetId(decal)
		if not id then
			return nil
		end
		local key = id .. ":" .. DECAL_SIZE
		if imageCache[key] == nil then
			pcall(loadImage, id, DECAL_SIZE)
		end
		return imageCache[key] or nil
	end

	prefetchDecals = function(root)
		if not fetchAsset then
			return
		end
		local pending, started = 0, {}
		for _, d in root:GetDescendants() do
			if d:IsA("Decal") then
				local id = decalAssetId(d)
				local key = id and id .. ":" .. DECAL_SIZE
				if key and imageCache[key] == nil and not started[key] then
					started[key] = true
					pending += 1
					task.spawn(function()
						pcall(loadImage, id, DECAL_SIZE)
						pending -= 1
					end)
				end
			end
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
	end

	-- Where luau_native can read meshes (Studio workers) MeshParts draw as real triangles; asset meshes
	-- load through AssetService first, which only works for meshes this server may load. Else a box.
	local AssetService = game:GetService("AssetService")
	local MESH_CACHE_LIMIT = 32
	local meshes, meshCount = {}, 0

	local function meshKey(part)
		local ok, content = pcall(function()
			return part.MeshContent
		end)
		if ok and content and content.Uri and content.Uri ~= "" then
			return content.Uri
		end
		local okId, id = pcall(function()
			return part.MeshId
		end)
		return if okId and id ~= "" then id else nil
	end

	local function loadMesh(part, key)
		meshes[key] = false
		local ok, editable = pcall(AssetService.CreateEditableMeshAsync, AssetService, part.MeshContent)
		if ok and editable then
			local okRead, geo = pcall(nativeImage.readMesh, editable)
			editable:Destroy()
			if okRead and geo then
				if meshCount >= MESH_CACHE_LIMIT then
					table.clear(meshes)
					meshCount = 0
				end
				meshes[key] = geo
				meshCount += 1
			end
		end
	end

	meshGeometry = function(part)
		-- an EditableMesh-backed MeshPart reads directly, and may change between renders
		local ok, geo = pcall(nativeImage.readMesh, part)
		if ok and geo then
			return geo
		end
		local key = meshKey(part)
		return key and meshes[key] or nil
	end

	prefetchMeshes = function(root)
		if not nativeImage.readMesh then
			return
		end
		local pending, started = 0, {}
		local function visit(d)
			if d:IsA("MeshPart") then
				local key = meshKey(d)
				if key and meshes[key] == nil and not started[key] then
					started[key] = true
					pending += 1
					task.spawn(function()
						pcall(loadMesh, d, key)
						pending -= 1
					end)
				end
			end
		end
		visit(root)
		for _, d in root:GetDescendants() do
			visit(d)
		end
		local deadline = os.clock() + 15
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
	end

	meshTexture = function(part)
		local id
		local appearance = part:FindFirstChildOfClass("SurfaceAppearance")
		if appearance then
			local ok, map = pcall(function()
				return appearance.ColorMap
			end)
			id = ok and parseAssetId(map)
		end
		if not id then
			local ok, tex = pcall(function()
				return part.TextureID
			end)
			id = ok and parseAssetId(tex)
		end
		if not id or not fetchAsset then
			return nil
		end
		local key = id .. ":" .. DECAL_SIZE
		if imageCache[key] == nil then
			pcall(loadImage, id, DECAL_SIZE)
		end
		return imageCache[key] or nil
	end

	local function ancestorLinks(target)
		local links = {}
		local cur = target.Parent
		while cur do
			for _, c in cur:GetChildren() do
				if c:IsA("StyleLink") then
					table.insert(links, c)
				end
			end
			cur = cur.Parent
		end
		return links
	end

	local function paintRoot(scratch, root, w, h, buf, links)
		pcall(styles.apply, root, links)
		sizeAutoText(root)
		prefetchImages(root)
		local writer = raster.writer()
		local ok, err = pcall(render2d.paint, root, {
			writer = writer,
			width = w,
			height = h,
			origin = root.AbsolutePosition,
			global = scratch.ZIndexBehavior == Enum.ZIndexBehavior.Global,
			imageFor = imageFor,
			yield = maybeYield,
		})
		scratch:Destroy()
		if ok then
			ok, err = pcall(runCommands, writer, w, h, buf)
		end
		if not ok then
			error(`fromInstance: {err}`, 5)
		end
	end

	-- Every enabled ScreenGui in the tree is drawn as its own layer by DisplayOrder, the way
	-- PlayerGui draws them; they may sit in Folders or inside other ScreenGuis (as Iris does).
	local function screenLayers(target)
		local list = {}
		local function walk(inst)
			for _, c in inst:GetChildren() do
				if c:IsA("ScreenGui") then
					if c.Enabled then
						table.insert(list, { c, #list })
						walk(c)
					end
				elseif not c:IsA("GuiObject") and not c:IsA("LayerCollector") then
					walk(c)
				end
			end
		end
		if target.Enabled then
			table.insert(list, { target, 0 })
			walk(target)
		end
		table.sort(list, function(a, b)
			if a[1].DisplayOrder ~= b[1].DisplayOrder then
				return a[1].DisplayOrder < b[1].DisplayOrder
			end
			return a[2] < b[2]
		end)
		return list
	end

	renderGui = function(target, size)
		local w, h
		local abs = target.AbsoluteSize
		w, h = if size then size.X else abs.X, if size then size.Y else abs.Y
		if target:IsA("LayerCollector") then
			if w < 1 or h < 1 then
				w, h = 800, 600
			end
			w, h = math.clamp(math.floor(w), 1, MAX_SIDE), math.clamp(math.floor(h), 1, MAX_SIDE)
			local buf = buffer.create(w * h * 4)
			local layers = if target:IsA("ScreenGui") then screenLayers(target) elseif target.Enabled then { { target } } else {}
			for _, entry in layers do
				local layer = entry[1]
				local scratch = Instance.new("ScreenGui")
				scratch.ZIndexBehavior = layer.ZIndexBehavior
				local root = Instance.new("Frame")
				root.BackgroundTransparency = 1
				root.BorderSizePixel = 0
				root.Size = UDim2.fromOffset(w, h)
				root.Parent = scratch
				for _, c in layer:GetChildren() do
					if not c:IsA("LayerCollector") then
						local copy = c:Clone()
						if copy then
							for _, d in copy:GetDescendants() do
								if d:IsA("LayerCollector") then
									d:Destroy()
								end
							end
							copy.Parent = root
						end
					end
				end
				paintRoot(scratch, root, w, h, buf)
			end
			local out = Image.new(Vector2.new(w, h))
			out.imageBuffer = buf
			return out
		end

		if w < 1 or h < 1 then
			error("fromInstance: this GUI object has no size; parent it to a ScreenGui or pass Size", 4)
		end
		w, h = math.clamp(math.floor(w), 1, MAX_SIDE), math.clamp(math.floor(h), 1, MAX_SIDE)
		local root = target:Clone()
		if not root then
			error("fromInstance: can't render an object whose Archivable is false", 4)
		end
		local scratch = Instance.new("ScreenGui")
		local collector = nearestCollector(target)
		scratch.ZIndexBehavior = if collector then collector.ZIndexBehavior else Enum.ZIndexBehavior.Sibling
		root.Position = UDim2.new()
		root.AnchorPoint = Vector2.zero
		root.Rotation = 0
		root.Size = UDim2.fromOffset(w, h)
		root.Parent = scratch
		local buf = buffer.create(w * h * 4)
		paintRoot(scratch, root, w, h, buf, ancestorLinks(target))
		local out = Image.new(Vector2.new(w, h))
		out.imageBuffer = buf
		return out
	end

	local function readOptions(name, root, options)
		if options ~= nil and type(options) ~= "table" then
			error(`{name}: arg 2 must be a table of options`, 3)
		end
		options = options or {}
		local target = renderTarget(root)
		if not target then
			error(`{name}: arg 1 must be workspace or an Instance from this run`, 3)
		end
		local size = options.Size
		if size ~= nil and typeof(size) ~= "Vector2" then
			error(`{name}: Size must be a Vector2`, 3)
		end
		local spec = { target = target, root = root, size = size }
		if target:IsA("GuiBase2d") and not target:IsA("ViewportFrame") then
			spec.gui = true
			return spec
		end

		local o = {}
		local cam = options.Camera
		if typeof(cam) == "CFrame" then
			o.camCF = cam
		elseif cam ~= nil then
			o.camCF, o.fov = readCamera(cam)
			if not o.camCF then
				error(`{name}: Camera must be a Camera or a CFrame`, 3)
			end
		end
		if options.FieldOfView ~= nil then
			if type(options.FieldOfView) ~= "number" then
				error(`{name}: FieldOfView must be a number`, 3)
			end
			o.fov = options.FieldOfView
		end
		local lightDir = options.LightDirection
		if lightDir ~= nil and (typeof(lightDir) ~= "Vector3" or lightDir.Magnitude == 0) then
			error(`{name}: LightDirection must be a non-zero Vector3`, 3)
		end
		o.lightDir = lightDir
		local bg = options.Background
		if bg ~= nil and bg ~= false and typeof(bg) ~= "Color3" then
			error(`{name}: Background must be a Color3 or false`, 3)
		end
		o.background = bg
		if options.AntiAliasing ~= nil and type(options.AntiAliasing) ~= "boolean" then
			error(`{name}: AntiAliasing must be a boolean`, 3)
		end
		if options.Materials ~= nil and type(options.Materials) ~= "boolean" then
			error(`{name}: Materials must be a boolean`, 3)
		end
		o.scale = if options.AntiAliasing == false then 1 else 2
		o.materials = options.Materials
		spec.o = o

		local defaultSize = Vector2.new(512, 512)
		if target:IsA("ViewportFrame") then
			local abs = target.AbsoluteSize
			if abs.X >= 1 and abs.Y >= 1 then
				defaultSize = abs
			end
		elseif target:IsA("WorldRoot") then
			defaultSize = Vector2.new(640, 360)
		end
		size = size or defaultSize
		spec.w = math.clamp(math.floor(size.X), 1, MAX_SIDE)
		spec.h = math.clamp(math.floor(size.Y), 1, MAX_SIDE)
		return spec
	end

	local function renderSpec(spec)
		lastYield = os.clock()
		if spec.gui then
			return renderGui(spec.target, spec.size)
		end
		local out = Image.new(Vector2.new(spec.w, spec.h))
		out.imageBuffer = render3dInto(spec.target, spec.root, spec.o, spec.w, spec.h)
		return out
	end

	Image.fromInstance = function(root, options)
		return renderSpec(readOptions("fromInstance", root, options))
	end

	-- record returns at once; every path ends the recording and Wait times out, so nothing yields forever.
	local MAX_DURATION, MAX_RATE, MAX_FRAMES = 30, 20, 256
	local FRAME_BUDGET = 64 * 1024 * 1024 -- RGBA bytes over all frames, the GIF encoder's cap
	local WAIT_GRACE = 60
	-- Each recording may hold FRAME_BUDGET; this module is loaded once per run.
	local MAX_ACTIVE_RECORDINGS, activeRecordings = 2, 0

	local function checkNumber(name, value, default, lo, hi)
		if value == nil then
			return default
		end
		if type(value) ~= "number" or value ~= value or value < lo or value > hi then
			error(`record: {name} must be a number from {lo} to {hi}`, 3)
		end
		return value
	end

	Image.record = function(root, options)
		if options ~= nil and type(options) ~= "table" then
			error("record: arg 2 must be a table of options", 2)
		end
		options = table.clone(options or {})
		local duration = checkNumber("Duration", options.Duration, 3, 0.05, MAX_DURATION)
		local rate = checkNumber("FrameRate", options.FrameRate, 10, 1, MAX_RATE)
		local maxFrames = math.floor(checkNumber("MaxFrames", options.MaxFrames, MAX_FRAMES, 1, MAX_FRAMES))
		local loop = math.floor(checkNumber("Loop", options.Loop, 0, 0, 65535))
		if options.Encode ~= nil and type(options.Encode) ~= "boolean" then
			error("record: Encode must be a boolean", 2)
		end
		local encode = options.Encode ~= false
		if options.AntiAliasing == nil then
			options.AntiAliasing = false
		end
		local spec = readOptions("record", root, options)
		if activeRecordings >= MAX_ACTIVE_RECORDINGS then
			error(`record: at most {MAX_ACTIVE_RECORDINGS} recordings can run at once`, 2)
		end
		if not spec.gui and options.Size == nil then
			spec.w, spec.h = math.min(spec.w, 320), math.min(spec.h, 180)
		end
		-- GIF frames have no partial transparency, so a model gets the sky behind it
		if not spec.gui and options.Background == nil then
			spec.o.background = "sky"
		end

		local rec = { Status = "recording", FrameCount = 0, Reason = nil }
		local stopped, destroyed = false, false
		local result, delays, failure
		local startedAt = os.clock()

		local conn
		pcall(function()
			conn = spec.target.Destroying:Connect(function()
				destroyed = true
			end)
		end)

		activeRecordings += 1
		task.defer(function()
			local frames, times = {}, {}
			local lastKey
			local interval = 1 / rate
			local nextAt = startedAt
			local bytes = 0
			local ok, err = pcall(function()
				while true do
					if stopped then
						rec.Reason = "stopped"
						break
					elseif destroyed then
						rec.Reason = "destroyed"
						break
					elseif os.clock() - startedAt >= duration then
						rec.Reason = "duration"
						break
					elseif #frames >= maxFrames then
						rec.Reason = "frames"
						break
					end
					local now = os.clock()
					local img = renderSpec(spec)
					local key = buffer.tostring(img.imageBuffer)
					if key == lastKey then
					elseif bytes + #key > FRAME_BUDGET then
						rec.Reason = "budget"
						break
					else
						bytes += #key
						lastKey = key
						table.insert(frames, img)
						table.insert(times, now)
						rec.FrameCount = #frames
					end
					nextAt += interval
					task.wait(math.max(nextAt - os.clock(), 0))
				end
				if #frames == 0 then
					error("no frames were captured")
				end
				local endAt = math.min(os.clock(), startedAt + duration)
				delays = table.create(#frames)
				for i = 1, #frames do
					delays[i] = math.max((times[i + 1] or endAt) - times[i], 0.02)
				end
				result = if encode then Image.toGif(frames, delays, { loop = loop }) else frames
			end)
			activeRecordings -= 1
			if conn then
				conn:Disconnect()
			end
			if ok then
				rec.Status = "done"
			else
				failure = `record: {err}`
				rec.Status = "failed"
				rec.Reason = rec.Reason or "error"
			end
		end)

		function rec.Stop(_self)
			stopped = true
		end

		-- GIF bytes (frames and delays with Encode = false), or nil and a reason on failure or
		-- timeout. The default timeout is the rest of Duration plus a minute.
		function rec.Wait(_self, timeout)
			if timeout ~= nil and (type(timeout) ~= "number" or timeout < 0) then
				error("record: Wait timeout must be a non-negative number", 2)
			end
			local deadline = os.clock() + (timeout or (startedAt + duration - os.clock() + WAIT_GRACE))
			while rec.Status == "recording" do
				if os.clock() >= deadline then
					return nil, "timeout"
				end
				task.wait()
			end
			if rec.Status == "failed" then
				return nil, failure
			end
			if encode then
				return result
			end
			return result, delays
		end

		return rec
	end

	Image.plotFunction = function(fx,options)
		return plotfunction(fx,options,Image,io)
	end
	return Image
end