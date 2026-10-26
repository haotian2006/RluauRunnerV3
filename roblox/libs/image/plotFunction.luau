local function plotFunction(func: (number) -> number, options: {
	offset: Vector2?,
	size: Vector2?,
	scale: number?,
	maxPixelSize: number?,
	isXFunction: boolean?,
	isParametric: boolean?,
	tRange: {number}?,
	color: ({Color3} | Color3)?,
	backgroundColor: Color3?,
	showAxes: boolean?,
	axesColor: Color3?,
	showGrid: boolean?,
	gridColor: Color3?,
	gridSpacing: number?,
	showLabels: boolean?,
	labelColor: Color3?,
	labelSpacing: number?,
	labelSize: number?,
	thickness: number?,
	filename: string?,
	},Image,io)
	options = options or {}
	local axisSize = options.size or Vector2.new(10, 8)
	local scale = options.scale or 50 -- shrunk to fit maxPixelSize
	local maxPixelSize = options.maxPixelSize or 1024
	axisSize*=2
	local pixelWidth = axisSize.X * scale
	local pixelHeight = axisSize.Y * scale

	if pixelWidth > maxPixelSize then
		scale = maxPixelSize / axisSize.X
		pixelWidth = maxPixelSize
	end
	if pixelHeight > maxPixelSize then
		scale = math.min(scale, maxPixelSize / axisSize.Y)
		pixelHeight = maxPixelSize
	end

	local size = Vector2.new(pixelWidth, pixelHeight)
	local offset = options.offset or Vector2.new(size.X / 2, size.Y / 2)
	local isXFunction = options.isXFunction or false
	local isParametric = options.isParametric or false
	local tRange = options.tRange or {0, 2 * math.pi}
	local colors = options.color or {
		Color3.new(1, 0, 0),
		Color3.new(0, 1, 0),
		Color3.new(0, 0, 1),
		Color3.new(1, 1, 0),
		Color3.new(1, 0, 1),
		Color3.new(0, 1, 1),
		Color3.new(1, 0.5, 0),
		Color3.new(0.5, 0, 1),
	}
	if type(colors.r) == "number" then
		colors = {colors}
	end
	local backgroundColor = options.backgroundColor or Color3.new(1, 1, 1)
	local showAxes = options.showAxes ~= false
	local axesColor = options.axesColor or Color3.new(0.3, 0.3, 0.3)
	local showGrid = options.showGrid or false
	local gridColor = options.gridColor or Color3.new(0.8, 0.8, 0.8)
	local gridSpacing = options.gridSpacing or 1
	local showLabels = options.showLabels ~= false
	local labelColor = options.labelColor or Color3.new(0, 0, 0)
	local baseLabelSpacing = options.labelSpacing or 1
	local labelSpacing = baseLabelSpacing
	if axisSize.X > 20 then
		labelSpacing = math.ceil(axisSize.X / 10)
	elseif axisSize.X > 10 then
		labelSpacing = math.ceil(axisSize.X / 8)
	end
	local labelSize = options.labelSize or 1
	local thickness = options.thickness or 1
	local filename = options.filename or "graph.png"

	local image = Image.new(size)
	image:Fill(backgroundColor, 0)

	if showGrid then
		local startX = math.floor(-offset.X / scale / gridSpacing) * gridSpacing
		local endX = math.ceil((size.X - offset.X) / scale / gridSpacing) * gridSpacing
		local startY = math.floor(-offset.Y / scale / gridSpacing) * gridSpacing
		local endY = math.ceil((size.Y - offset.Y) / scale / gridSpacing) * gridSpacing

		for x = startX, endX, gridSpacing do
			local screenX = offset.X + x * scale
			if screenX >= 0 and screenX <= size.X then
				image:DrawLine(
					Vector2.new(screenX, 0),
					Vector2.new(screenX, size.Y),
					gridColor,
					0
				)
			end
		end

		for y = startY, endY, gridSpacing do
			local screenY = offset.Y - y * scale
			if screenY >= 0 and screenY <= size.Y then
				image:DrawLine(
					Vector2.new(0, screenY),
					Vector2.new(size.X, screenY),
					gridColor,
					0
				)
			end
		end
	end

	local isXY = type(func(0,0)) == "boolean" -- f(x, y) returning booleans

	local step = 0.01 / scale
	local plottedCurves = {}
	local startTime = os.clock()

	if isXY then
		local startX = -offset.X / scale
		local endX = (size.X - offset.X) / scale
		local startY = -(size.Y - offset.Y) / scale
		local endY = offset.Y / scale

		local pixelStep = 1 / scale

		for x = startX, endX, pixelStep do
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			for y = startY, endY, pixelStep do
				local results = {pcall(func, x, y)}
				local success = table.remove(results, 1)

				if success and #results > 0 then
					for i, value in ipairs(results) do
						if type(value) == "boolean" and value then
							plottedCurves[i] = true

							local screenX = offset.X + x * scale
							local screenY = offset.Y - y * scale

							if screenX >= 0 and screenX < size.X and screenY >= 0 and screenY < size.Y then
								local regionColor = colors[((i - 1) % #colors) + 1]
								image:SetPixel(math.floor(screenX), math.floor(screenY), regionColor, 0)
							end
						end
					end
				elseif not success then
					error("Error in function: " .. tostring(results[1]))
				end
			end
		end

	elseif isParametric then
		local tStart = tRange[1]
		local tEnd = tRange[2]
		local tStep = (tEnd - tStart) / (size.X * 2)

		local prevScreenPositions = {}

		for t = tStart, tEnd, tStep do
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			local results = {pcall(func, t)}
			local success = table.remove(results, 1)

			if success and #results >= 1 then
				local curveData = {}
				if type(results[1]) == "table" then
					-- Table format: {{x1,y1}, {x2,y2}, ...}
					curveData = results
				else
					-- Flat format: x1, y1, x2, y2, ...
					local pairCount = math.floor(#results / 2)
					for i = 1, pairCount do
						curveData[i] = {results[(i - 1) * 2 + 1], results[(i - 1) * 2 + 2]}
					end
				end

				for i, point in ipairs(curveData) do
					local x, y = point[1], point[2]
					if type(x) == "number" and type(y) == "number" and x == x and y == y then
						plottedCurves[i] = true
						local screenX = offset.X + x * scale
						local screenY = offset.Y - y * scale

						if screenX >= -thickness and screenX <= size.X + thickness and screenY >= -thickness and screenY <= size.Y + thickness then
							local screenPos = Vector2.new(screenX, screenY)

							if prevScreenPositions[i] then
								local curveColor = colors[((i - 1) % #colors) + 1]
								if thickness > 1 then
									for k = 0, thickness - 1 do
										image:DrawLine(
											Vector2.new(prevScreenPositions[i].X + k - thickness/2, prevScreenPositions[i].Y + k - thickness/2),
											Vector2.new(screenPos.X + k - thickness/2, screenPos.Y + k - thickness/2),
											curveColor,
											0
										)
									end
								else
									image:DrawLine(prevScreenPositions[i], screenPos, curveColor, 0)
								end
							end

							prevScreenPositions[i] = screenPos
						else
							prevScreenPositions[i] = nil
						end
					else
						prevScreenPositions[i] = nil
					end
				end
			elseif not success then
				error("Error in function: " .. tostring(results[1]))
			end
		end

	elseif not isXFunction then
		local startX = -offset.X / scale
		local endX = (size.X - offset.X) / scale

		local prevScreenPositions = {}

		for x = startX, endX, step do
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			local results = {pcall(func, x)}
			local success = table.remove(results, 1)

			if success and #results > 0 then
				for i, y in ipairs(results) do
					if type(y) == "number" and y == y then -- Check for NaN
						plottedCurves[i] = true
						local screenX = offset.X + x * scale
						local screenY = offset.Y - y * scale

						if screenX >= 0 and screenX <= size.X and screenY >= -thickness and screenY <= size.Y + thickness then
							local screenPos = Vector2.new(screenX, screenY)

							if prevScreenPositions[i] then
								local curveColor = colors[((i - 1) % #colors) + 1]
								if thickness > 1 then
									for t = 0, thickness - 1 do
										image:DrawLine(
											Vector2.new(prevScreenPositions[i].X, prevScreenPositions[i].Y + t - thickness/2),
											Vector2.new(screenPos.X, screenPos.Y + t - thickness/2),
											curveColor,
											0
										)
									end
								else
									image:DrawLine(prevScreenPositions[i], screenPos, curveColor, 0)
								end
							end

							prevScreenPositions[i] = screenPos
						else
							prevScreenPositions[i] = nil
						end
					else
						prevScreenPositions[i] = nil
					end
				end
			elseif not success then
				error("Error in function: " .. tostring(results[1]))

			end
		end

	else
		local startY = -(size.Y - offset.Y) / scale
		local endY = offset.Y / scale

		local prevScreenPositions = {}

		for y = startY, endY, step do
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			local results = {pcall(func, y)}
			local success = table.remove(results, 1)

			if success and #results > 0 then
				for i, x in ipairs(results) do
					if type(x) == "number" and x == x then
						plottedCurves[i] = true
						local screenX = offset.X + x * scale
						local screenY = offset.Y - y * scale

						if screenY >= 0 and screenY <= size.Y and screenX >= -thickness and screenX <= size.X + thickness then
							local screenPos = Vector2.new(screenX, screenY)

							if prevScreenPositions[i] then
								local curveColor = colors[((i - 1) % #colors) + 1]
								if thickness > 1 then
									for t = 0, thickness - 1 do
										image:DrawLine(
											Vector2.new(prevScreenPositions[i].X + t - thickness/2, prevScreenPositions[i].Y),
											Vector2.new(screenPos.X + t - thickness/2, screenPos.Y),
											curveColor,
											0
										)
									end
								else
									image:DrawLine(prevScreenPositions[i], screenPos, curveColor, 0)
								end
							end

							prevScreenPositions[i] = screenPos
						else
							prevScreenPositions[i] = nil
						end
					else
						prevScreenPositions[i] = nil
					end
				end
			elseif not success then
				error("Error in function: " .. tostring(results[1]))
			end
		end
	end

	local curveCount = 0
	for _ in pairs(plottedCurves) do
		curveCount = curveCount + 1
	end

	if curveCount > 1 then
		local legendX = 10
		local legendY = 10
		local lineHeight = 16
		local lineLength = 20
		local textOffset = 25

		local curveIndices = {}
		for i in pairs(plottedCurves) do
			table.insert(curveIndices, i)
		end
		table.sort(curveIndices)

		for _, i in ipairs(curveIndices) do
			local curveColor = colors[((i - 1) % #colors) + 1]
			local yPos = legendY + (_ - 1) * lineHeight

			if thickness > 1 then
				for t = 0, thickness - 1 do
					image:DrawLine(
						Vector2.new(legendX + textOffset, yPos + 4 + t - thickness/2),
						Vector2.new(legendX + textOffset + lineLength, yPos + 4 + t - thickness/2),
						curveColor,
						0
					)
				end
			else
				image:DrawLine(
					Vector2.new(legendX + textOffset, yPos + 4),
					Vector2.new(legendX + textOffset + lineLength, yPos + 4),
					curveColor,
					0
				)
			end

			local label = "F(" .. i .. "):"
			image:DrawText(
				label,
				Vector2.new(legendX, yPos),
				labelColor,
				0,
				1
			)
		end
	end

	if showAxes then
		if offset.Y >= 0 and offset.Y <= size.Y then
			image:DrawLine(
				Vector2.new(0, offset.Y),
				Vector2.new(size.X, offset.Y),
				axesColor,
				0
			)
		end

		if offset.X >= 0 and offset.X <= size.X then
			image:DrawLine(
				Vector2.new(offset.X, 0),
				Vector2.new(offset.X, size.Y),
				axesColor,
				0
			)
		end
	end

	if showLabels and showAxes then
		local startX = math.floor(-offset.X / scale / labelSpacing) * labelSpacing
		local endX = math.ceil((size.X - offset.X) / scale / labelSpacing) * labelSpacing
		local startY = math.floor(-(size.Y - offset.Y) / scale / labelSpacing) * labelSpacing
		local endY = math.ceil(offset.Y / scale / labelSpacing) * labelSpacing

		if offset.Y >= 0 and offset.Y <= size.Y then
			for x = startX, endX, labelSpacing do
				if x ~= 0 then
					local screenX = offset.X + x * scale
					if screenX >= 10 and screenX <= size.X - 10 then
						image:DrawLine(
							Vector2.new(screenX, offset.Y - 3),
							Vector2.new(screenX, offset.Y + 3),
							axesColor,
							0
						)

						local label = tostring(x)
						if math.floor(x) == x then
							label = tostring(math.floor(x))
						end

						local labelOffset = 8
						if offset.Y > size.Y - 20 then
							labelOffset = -12
						end

						image:DrawText(
							label,
							Vector2.new(screenX - (#label * 3 * labelSize), offset.Y + labelOffset),
							labelColor,
							0,
							labelSize
						)
					end
				end
			end
		end

		if offset.X >= 0 and offset.X <= size.X then
			for y = startY, endY, labelSpacing do
				if y ~= 0 then
					local screenY = offset.Y - y * scale
					if screenY >= 10 and screenY <= size.Y - 10 then
						image:DrawLine(
							Vector2.new(offset.X - 3, screenY),
							Vector2.new(offset.X + 3, screenY),
							axesColor,
							0
						)

						local label = tostring(y)
						if math.floor(y) == y then
							label = tostring(math.floor(y))
						end

						local labelOffset = -10 - (#label * 6 * labelSize)
						if offset.X < 40 then
							labelOffset = 10
						end

						image:DrawText(
							label,
							Vector2.new(offset.X + labelOffset, screenY - 4),
							labelColor,
							0,
							labelSize
						)
					end
				end
			end
		end

		if offset.X >= 20 and offset.X <= size.X - 20 and offset.Y >= 20 and offset.Y <= size.Y - 20 then
			image:DrawText(
				"0",
				Vector2.new(offset.X - 12, offset.Y + 8),
				labelColor,
				0,
				labelSize
			)
		end
	end

	local pngData = Image.toPng(image, false)
	io.writefile(pngData, filename)
	return image
end



return plotFunction