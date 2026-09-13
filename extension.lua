-- Clone Stamp Extension for Aseprite
-- Custom tiled canvas, pan/zoom, smoothstep brush, and max-coverage strokes.
-- workImg, snapshot, and undo images all use sprite-canvas coordinates.
-- Apply replaces a detached image in one native undoable transaction.
-- API: Aseprite >= 1.3 (Dialog:canvas support required).

local TILED_NONE, TILED_X, TILED_Y, TILED_BOTH = 0, 1, 2, 3

-- =========================================================================
-- Session state (no document pixels are modified before Apply)
-- =========================================================================
local dlg = nil
local sessionBusy, exiting = false, false
local radius, softness, opacity, spacing = 16, 0.5, 1.0, 0.25
local workImg, sourcePoint, offset, snapshot = nil, nil, nil, nil
local undoStack, undoPos = nil, 0
local tiledMode = TILED_NONE
local celX, celY, celColorMode = 0, 0, nil
local sessionSprite, sessionLayer, sessionFrame = nil, nil, nil
local originalCel, originalImageId, originalImageVersion = nil, nil, nil
local backgroundLayer, transparentIndex = false, 0
local paletteColors, paletteSize, paletteCache, paletteCacheSize = nil, 0, nil, 0
local brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1
local alphaAcc, colorAcc = nil, nil
local dirtyX1, dirtyY1, dirtyX2, dirtyY2 = 0, 0, -1, -1
local selMask, selBounds, selEdgeImg = nil, nil, nil

local function boundedNumber(value, fallback, minimum, maximum, integer)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		value = fallback
	end
	value = math.max(minimum, math.min(maximum, value))
	if integer then value = math.floor(value + 0.5) end
	return value
end

local function resetAccum()
	alphaAcc, colorAcc = nil, nil
	dirtyX1, dirtyY1, dirtyX2, dirtyY2 = 0, 0, -1, -1
end

local function disposeState()
	workImg, sourcePoint, offset, snapshot = nil, nil, nil, nil
	undoStack, undoPos = nil, 0
	sessionSprite, sessionLayer, sessionFrame = nil, nil, nil
	originalCel, originalImageId, originalImageVersion = nil, nil, nil
	celX, celY, celColorMode = 0, 0, nil
	backgroundLayer, transparentIndex = false, 0
	paletteColors, paletteSize, paletteCache, paletteCacheSize = nil, 0, nil, 0
	brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1
	selMask, selBounds, selEdgeImg = nil, nil, nil
	resetAccum()
end

local function layerProblem(layer, sprite)
	if not layer or not layer.isImage or layer.isTilemap or layer.isReference then
		return "Clone Stamp requires a raster image layer, not a tilemap or reference layer."
	end
	local current = layer
	while current do
		if not current.isEditable then return "The layer or one of its groups is locked." end
		local parent = current.parent
		if not parent or parent == sprite then break end
		current = parent
	end
end

local function newSessionImage(width, height)
	-- Preserve the image's color profile and nonzero indexed transparency index.
	local spec = ImageSpec(originalCel.spec)
	spec.width, spec.height = width, height
	if celColorMode == ColorMode.INDEXED then spec.transparentColor = transparentIndex end
	local image = Image(spec)
	image:clear()
	return image
end

local function copyPixels(source, destination, dx, dy)
	-- Raw replacement preserves transparent pixels and hidden RGB/index values.
	local x1, y1 = math.max(0, -dx), math.max(0, -dy)
	local x2 = math.min(source.width - 1, destination.width - 1 - dx)
	local y2 = math.min(source.height - 1, destination.height - 1 - dy)
	for y = y1, y2 do
		for x = x1, x2 do
			destination:drawPixel(x + dx, y + dy, source:getPixel(x, y))
		end
	end
end

local function capturePalette(sprite, frameNumber)
	local chosen, chosenFrame = nil, -1
	for _, palette in ipairs(sprite.palettes) do
		local frame = palette.frame
		local number = frame and frame.frameNumber or 1
		if number <= frameNumber and number >= chosenFrame then
			chosen, chosenFrame = palette, number
		end
	end
	if not chosen or #chosen == 0 then return false end
	paletteSize = math.min(256, #chosen)
	paletteColors, paletteCache, paletteCacheSize = {}, {}, 0
	for index = 0, paletteSize - 1 do
		local color = chosen:getColor(index)
		paletteColors[index] = { color.red, color.green, color.blue, color.alpha }
	end
	return true
end

local function initState(prefs)
	disposeState()
	local sprite, activeCel = app.activeSprite, app.activeCel
	if not sprite or not activeCel then return false, "No active cel!" end
	local problem = layerProblem(activeCel.layer, sprite)
	if problem then return false, problem end
	local mode = activeCel.image.colorMode
	if mode ~= ColorMode.RGB and mode ~= ColorMode.GRAYSCALE and mode ~= ColorMode.INDEXED then
		return false, "Unsupported image color mode."
	end

	sessionSprite, sessionLayer, sessionFrame = sprite, activeCel.layer, activeCel.frameNumber
	celX, celY = activeCel.position.x, activeCel.position.y
	celColorMode = mode
	backgroundLayer = sessionLayer.isBackground
	transparentIndex = sprite.transparentColor
	originalCel = Image(activeCel.image)
	originalImageId, originalImageVersion = activeCel.image.id, activeCel.image.version
	if mode == ColorMode.INDEXED and not capturePalette(sprite, sessionFrame) then
		return false, "The active frame has no usable palette."
	end

	radius = boundedNumber(prefs.radius, 16, 1, 64, true)
	softness = boundedNumber(prefs.softness, 0.5, 0, 1)
	opacity = boundedNumber(prefs.opacity, 1, 0, 1)
	spacing, tiledMode = 0.25, TILED_NONE
	workImg = newSessionImage(sprite.width, sprite.height)
	copyPixels(originalCel, workImg, celX, celY)
	snapshot = Image(workImg)
	undoStack, undoPos = { [0] = Image(workImg) }, 0

	local selection = sprite.selection
	if selection and not selection.isEmpty then
		selMask = Image(sprite.width, sprite.height, ColorMode.GRAYSCALE)
		selMask:clear()
		selEdgeImg = Image(sprite.width, sprite.height, ColorMode.GRAYSCALE)
		selEdgeImg:clear()
		selBounds = selection.bounds
		local x1, y1 = math.max(0, selBounds.x), math.max(0, selBounds.y)
		local x2 = math.min(sprite.width - 1, selBounds.x + selBounds.width - 1)
		local y2 = math.min(sprite.height - 1, selBounds.y + selBounds.height - 1)
		for y = y1, y2 do
			for x = x1, x2 do
				if selection:contains(x, y) then selMask:drawPixel(x, y, 255) end
			end
		end
		for y = y1, y2 do
			for x = x1, x2 do
				if selMask:getPixel(x, y) ~= 0 then
					local mask = 0
					if y == 0 or selMask:getPixel(x, y - 1) == 0 then mask = mask + 1 end
					if x == sprite.width - 1 or selMask:getPixel(x + 1, y) == 0 then mask = mask + 2 end
					if y == sprite.height - 1 or selMask:getPixel(x, y + 1) == 0 then mask = mask + 4 end
					if x == 0 or selMask:getPixel(x - 1, y) == 0 then mask = mask + 8 end
					selEdgeImg:drawPixel(x, y, mask)
				end
			end
		end
	end
	return true
end

local function savePrefs(prefs)
	prefs.radius, prefs.softness, prefs.opacity = radius, softness, opacity
end

-- =========================================================================
-- Pixel blending shared by real strokes and hover preview
-- =========================================================================
local function pixelRGBA(pixel)
	local pc = app.pixelColor
	if celColorMode == ColorMode.RGB then
		return pc.rgbaR(pixel), pc.rgbaG(pixel), pc.rgbaB(pixel),
			backgroundLayer and 255 or pc.rgbaA(pixel)
	elseif celColorMode == ColorMode.GRAYSCALE then
		local value = pc.grayaV(pixel)
		return value, value, value, backgroundLayer and 255 or pc.grayaA(pixel)
	end
	if not backgroundLayer and pixel == transparentIndex then return 0, 0, 0, 0 end
	local color = paletteColors and paletteColors[pixel]
	if not color then return 0, 0, 0, 0 end
	return color[1], color[2], color[3], backgroundLayer and 255 or color[4]
end

local function nearestPaletteIndex(red, green, blue, alpha, fallback)
	local key = app.pixelColor.rgba(red, green, blue, alpha)
	local cached = paletteCache[key]
	if cached ~= nil then return cached end
	local bestIndex, bestDistance = fallback, math.huge
	-- Match Aseprite's five-bit, weighted RGBA best-fit metric, but use the
	-- captured frame palette and exclude the mask only on transparent layers.
	local r, g, b, a = math.floor(red/8), math.floor(green/8), math.floor(blue/8), math.floor(alpha/8)
	for index = 0, paletteSize - 1 do
		if backgroundLayer or index ~= transparentIndex then
			local color = paletteColors[index]
			local dr, dg, db = math.floor(color[1]/8)-r, math.floor(color[2]/8)-g, math.floor(color[3]/8)-b
			local da = math.floor((backgroundLayer and 255 or color[4])/8)-a
			local distance = dr*dr*900 + dg*dg*3481 + db*db*121 + da*da*64
			if distance < bestDistance then
				bestDistance, bestIndex = distance, index
				if distance == 0 then break end
			end
		end
	end
	-- Bound only this disposable lookup cache; never truncate undo history.
	if paletteCacheSize >= 4096 then paletteCache, paletteCacheSize = {}, 0 end
	paletteCache[key] = bestIndex
	paletteCacheSize = paletteCacheSize+1
	return bestIndex
end

local function blendPixel(source, destination, coverage)
	if coverage <= 0 or source == destination then return destination end
	-- Exact endpoints preserve duplicate palette indices and hidden RGB bytes.
	if coverage >= 255 then return source end
	if celColorMode == ColorMode.INDEXED then
		if (not backgroundLayer and (source == transparentIndex or destination == transparentIndex)) or
		   not paletteColors[source] or not paletteColors[destination] then
			-- Keep the existing binary indexed-mask rule; no dithering is added.
			return coverage > 127 and source or destination
		end
	end
	local sr, sg, sb, sa = pixelRGBA(source)
	local dr, dg, db, da = pixelRGBA(destination)
	local sourceWeight, destinationWeight = sa*coverage, da*(255-coverage)
	local totalWeight = sourceWeight + destinationWeight
	local outAlpha = math.floor(totalWeight/255 + 0.5)
	local red, green, blue = 0, 0, 0
	if outAlpha > 0 then
		red = math.floor((sr*sourceWeight + dr*destinationWeight)/totalWeight + 0.5)
		green = math.floor((sg*sourceWeight + dg*destinationWeight)/totalWeight + 0.5)
		blue = math.floor((sb*sourceWeight + db*destinationWeight)/totalWeight + 0.5)
	end
	if celColorMode == ColorMode.GRAYSCALE then
		return app.pixelColor.graya(red, outAlpha)
	elseif celColorMode == ColorMode.INDEXED then
		return nearestPaletteIndex(red, green, blue, outAlpha, destination)
	end
	return app.pixelColor.rgba(red, green, blue, outAlpha)
end

local function makeDisplayImage(image)
	if celColorMode == ColorMode.RGB and not backgroundLayer then return image end
	local spec = ImageSpec(image.spec)
	spec.colorMode = ColorMode.RGB
	spec.transparentColor = 0
	local display = Image(spec)
	for y = 0, image.height - 1 do
		for x = 0, image.width - 1 do
			local r, g, b, a = pixelRGBA(image:getPixel(x, y))
			display:drawPixel(x, y, app.pixelColor.rgba(r, g, b, a))
		end
	end
	return display
end

-- =========================================================================
-- Apply: preserve off-canvas pixels, linked cels, and native undo/redo
-- =========================================================================
local function getWorkDirtyBounds()
	local original = undoStack and undoStack[0]
	if not workImg or not original then return 0, 0, -1, -1 end
	local x1, y1, x2, y2 = workImg.width, workImg.height, -1, -1
	for y = 0, workImg.height - 1 do
		for x = 0, workImg.width - 1 do
			if workImg:getPixel(x, y) ~= original:getPixel(x, y) then
				x1, y1 = math.min(x1, x), math.min(y1, y)
				x2, y2 = math.max(x2, x), math.max(y2, y)
			end
		end
	end
	return x1, y1, x2, y2
end

local function applyToCel()
	if not app.activeSprite or app.activeSprite.id ~= sessionSprite.id then
		error("The active sprite changed while Clone Stamp was open. Changes were not applied.")
	end
	local activeCel = sessionLayer:cel(sessionFrame)
	if not activeCel then error("The original cel no longer exists.") end
	local problem = layerProblem(sessionLayer, sessionSprite)
	if problem then error(problem) end
	if sessionSprite.width ~= workImg.width or sessionSprite.height ~= workImg.height or
	   activeCel.position.x ~= celX or activeCel.position.y ~= celY or
	   activeCel.image.id ~= originalImageId or activeCel.image.version ~= originalImageVersion then
		error("The original cel or canvas changed while Clone Stamp was open. Changes were not applied.")
	end
	local x1, y1, x2, y2 = getWorkDirtyBounds()
	if x1 > x2 or y1 > y2 then return end
	local left, top = math.min(celX, x1), math.min(celY, y1)
	local right = math.max(celX + originalCel.width - 1, x2)
	local bottom = math.max(celY + originalCel.height - 1, y2)
	local newImage
	if left == celX and top == celY and right == celX + originalCel.width - 1 and
	   bottom == celY + originalCel.height - 1 then
		newImage = Image(originalCel)
	else
		newImage = newSessionImage(right-left+1, bottom-top+1)
		copyPixels(originalCel, newImage, celX-left, celY-top)
	end
	for y = y1, y2 do
		for x = x1, x2 do
			newImage:drawPixel(x-left, y-top, workImg:getPixel(x, y))
		end
	end
	-- drawPixel on an attached cel is NOT undoable, even in a transaction.
	-- The image setter records the replacement and retains native cel links.
	activeCel.image = newImage
	if left ~= celX or top ~= celY then activeCel.position = Point(left, top) end
end

-- =========================================================================
-- Brush mask, coordinates, and per-stroke maximum coverage
-- =========================================================================
local function smoothstep(t)
	return 3*t*t - 2*t*t*t
end

local function ensureBrushMask()
	if brushMaskR == radius and brushMaskS == softness and brushMaskO == opacity then return end
	brushMaskR, brushMaskS, brushMaskO = radius, softness, opacity
	brushMask = Image(radius*2+1, radius*2+1, ColorMode.GRAYSCALE)
	brushMask:clear()
	local inner = radius*(1-softness)
	for dy = -radius, radius do
		for dx = -radius, radius do
			local distance, value = math.sqrt(dx*dx+dy*dy), 0
			if distance < radius then
				if softness <= 0 or distance <= inner then value = 1
				else value = 1-smoothstep((distance-inner)/(radius-inner)) end
			end
			brushMask:drawPixel(dx+radius, dy+radius, math.floor(value*opacity*255+0.5))
		end
	end
end

local function isTiledX() return tiledMode == TILED_X or tiledMode == TILED_BOTH end
local function isTiledY() return tiledMode == TILED_Y or tiledMode == TILED_BOTH end

local function workCoordinates(x, y)
	if isTiledX() then x = x % workImg.width
	elseif x < 0 or x >= workImg.width then return nil end
	if isTiledY() then y = y % workImg.height
	elseif y < 0 or y >= workImg.height then return nil end
	return x, y
end

local function sampleSource(tx, ty, offX, offY)
	local x, y = workCoordinates(tx-offX, ty-offY)
	-- Missing source is different from a valid transparent pixel/index zero.
	if x == nil then return nil end
	return snapshot:getPixel(x, y)
end

local function forBrushPixels(cx, cy, offX, offY, visit)
	local r = brushMaskR
	for my = 0, brushMask.height-1 do
		for mx = 0, brushMask.width-1 do
			local coverage = brushMask:getPixel(mx, my)
			if coverage > 0 then
				local x, y = workCoordinates(cx+mx-r, cy+my-r)
				if x ~= nil and (not selMask or selMask:getPixel(x, y) ~= 0) then
					local source = sampleSource(x, y, offX, offY)
					if source ~= nil then visit(x, y, source, coverage) end
				end
			end
		end
	end
end

local function beginAccum()
	alphaAcc = Image(workImg.width, workImg.height, ColorMode.GRAYSCALE)
	alphaAcc:clear()
	colorAcc = newSessionImage(workImg.width, workImg.height)
	dirtyX1, dirtyY1, dirtyX2, dirtyY2 = workImg.width, workImg.height, -1, -1
end

local function stampWithMask(cx, cy, offX, offY)
	forBrushPixels(cx, cy, offX, offY, function(x, y, source, coverage)
		if alphaAcc:getPixel(x, y) >= coverage then return end
		alphaAcc:drawPixel(x, y, coverage)
		colorAcc:drawPixel(x, y, source)
		dirtyX1, dirtyY1 = math.min(dirtyX1, x), math.min(dirtyY1, y)
		dirtyX2, dirtyY2 = math.max(dirtyX2, x), math.max(dirtyY2, y)
	end)
end

local function flushAccumTo(destination)
	if not alphaAcc or dirtyX1 > dirtyX2 or dirtyY1 > dirtyY2 then return end
	for y = dirtyY1, dirtyY2 do
		for x = dirtyX1, dirtyX2 do
			local coverage = alphaAcc:getPixel(x, y)
			if coverage > 0 then
				destination:drawPixel(x, y, blendPixel(colorAcc:getPixel(x, y), destination:getPixel(x, y), coverage))
			end
		end
	end
end

local function stampSegment(x1, y1, x2, y2, offX, offY)
	local step = math.max(1, math.floor(brushMaskR*spacing))
	local dx, dy = x2-x1, y2-y1
	local count = math.max(1, math.ceil(math.sqrt(dx*dx+dy*dy)/step))
	for i = 1, count do
		local t = i/count
		stampWithMask(math.floor(x1+dx*t+0.5), math.floor(y1+dy*t+0.5), offX, offY)
	end
end

local function markerPath(gc, x, y, r)
	gc:beginPath()
	gc:oval(Rectangle(x-r, y-r, r*2, r*2))
	gc:moveTo(x-4, y)
	gc:lineTo(x+4, y)
	gc:moveTo(x, y-4)
	gc:lineTo(x, y+4)
end

local function drawMarker(gc, x, y, r, highContrast)
	if highContrast then
		gc:save()
		gc.blendMode = BlendMode.NORMAL

		-- Dark outer stroke plus light inner stroke keeps the source
		-- marker visible over both light and dark artwork.
		gc.strokeWidth = 3
		gc.color = Color{ red=32, green=32, blue=32, alpha=255 }
		markerPath(gc, x, y, r)
		gc:stroke()

		gc.strokeWidth = 1
		gc.color = Color{ red=200, green=200, blue=200, alpha=255 }
		markerPath(gc, x, y, r)
		gc:stroke()

		gc:restore()
	else
		gc.strokeWidth = 1
		markerPath(gc, x, y, r)
		gc:stroke()
	end
end

-- =========================================================================
-- Dialog (same controls, modal behavior, and shortcuts)
-- =========================================================================
local function errorTraceback(message)
	local text = tostring(message)
	if debug and debug.traceback then
		return debug.traceback(text, 2)
	end
	return text
end

local function reportFailure(message, err)
	local report = tostring(err)
	local separator = package.config:sub(1, 1)
	local tempPath = os.getenv("TEMP") or os.getenv("TMP") or "."
	local errorPath = tempPath .. separator .. "stamp-brush-error.txt"
	local reportWritten = false

	if io and io.open then
		local errorFile = io.open(errorPath, "wb")
		if errorFile then
			errorFile:write(report)
			if report:sub(-1) ~= "\n" then
				errorFile:write("\n")
			end
			errorFile:close()
			reportWritten = true
		end
	end

	local summary = nil
	for line in report:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		local tail = trimmed:match("^.*:%s+(.+)$")

		if tail and
		   tail ~= "stack traceback:" and
		   not tail:match("^in function") and
		   not tail:match("^in upvalue") and
		   not tail:match("^in method") and
		   not tail:match("^in main chunk") then
			summary = tail
		end
	end

	summary = summary or "Unknown error"
	if #summary > 120 then
		summary = summary:sub(1, 117) .. "..."
	end

	local lines = { message, summary }

	if reportWritten then
		table.insert(lines, "")
		table.insert(lines, "Full error report written to:")
		table.insert(lines, errorPath)
	else
		table.insert(lines, "")
		table.insert(lines, "Could not write the full error report.")
	end

	app.alert{
		title="Clone Stamp",
		text=lines
	}
end

local function stampBrushDialog(prefs)
	local ready, reason = initState(prefs)
	if not ready then disposeState(); app.alert(reason); return end
	local isDrawing, isPanning, spaceHeld = false, false, false
	local panButton, requestedAction = nil, nil
	local mouseX, mouseY = -1, -1
	local lastWX, lastWY, strokeOffsetBefore = nil, nil, nil
	local previewImg, previewDisplay, baseDisplay, stampPreview = nil, nil, nil, nil
	local hoverPixels, hoverDirty = {}, true
	local stampPWX, stampPWY = nil, nil
	local vScale, vOffX, vOffY, minScale = 1, 0, 0, 0.5
	local panSX, panSY, panOX, panOY = 0, 0, 0, 0
	local centered = false

	local function toWork(x, y)
		return math.floor((x-vOffX)/vScale), math.floor((y-vOffY)/vScale)
	end
	local function toCanvas(x, y)
		return math.floor(x*vScale+vOffX+vScale/2+0.5), math.floor(y*vScale+vOffY+vScale/2+0.5)
	end

	local function invalidatePreview()
		previewImg, previewDisplay, baseDisplay, stampPreview = nil, nil, nil, nil
		hoverPixels, hoverDirty = {}, true
		stampPWX, stampPWY = nil, nil
	end

	local function updateStampPreview(wx, wy, offX, offY)
		if offX == nil or offY == nil then stampPreview = nil; return end
		ensureBrushMask()
		if not baseDisplay then baseDisplay = makeDisplayImage(workImg) end
		if not stampPreview then stampPreview = Image(baseDisplay); hoverPixels = {} end
		-- Restore the previous footprint before moving it. Do not blend previews
		-- over previews, and do not modify workImg or the stroke accumulator.
		for key in pairs(hoverPixels) do
			local x, y = key % workImg.width, math.floor(key/workImg.width)
			stampPreview:drawPixel(x, y, baseDisplay:getPixel(x, y))
		end
		hoverPixels = {}
		forBrushPixels(wx, wy, offX, offY, function(x, y, source, coverage)
			local key = y*workImg.width+x
			if (hoverPixels[key] or 0) >= coverage then return end
			hoverPixels[key] = coverage
			local result = blendPixel(source, workImg:getPixel(x, y), coverage)
			local r, g, b, a = pixelRGBA(result)
			stampPreview:drawPixel(x, y, app.pixelColor.rgba(r, g, b, a))
		end)
		stampPWX, stampPWY, hoverDirty = wx, wy, false
	end

	local function updatePreview()
		stampPreview, hoverPixels = nil, {}
		if not alphaAcc then return end
		previewImg = Image(workImg)
		flushAccumTo(previewImg)
		previewDisplay = makeDisplayImage(previewImg)
	end

	local function strokeChanged()
		if dirtyX1 > dirtyX2 or dirtyY1 > dirtyY2 then return false end
		local previous = undoStack[undoPos]
		for y = dirtyY1, dirtyY2 do
			for x = dirtyX1, dirtyX2 do
				if workImg:getPixel(x, y) ~= previous:getPixel(x, y) then return true end
			end
		end
		return false
	end

	local function pushUndo()
		undoPos = undoPos+1
		for i = undoPos, #undoStack do undoStack[i] = nil end
		undoStack[undoPos] = Image(workImg)
	end

	local function cancelStroke()
		if isDrawing then offset = strokeOffsetBefore end
		isDrawing = false
		lastWX, lastWY, strokeOffsetBefore = nil, nil, nil
		resetAccum()
		invalidatePreview()
	end

	local function finishStroke()
		if not isDrawing then return end
		flushAccumTo(workImg)
		if strokeChanged() then pushUndo() else offset = strokeOffsetBefore end
		snapshot = Image(workImg)
		isDrawing = false
		lastWX, lastWY, strokeOffsetBefore = nil, nil, nil
		resetAccum()
		invalidatePreview()
	end

	local function undo()
		if isDrawing then cancelStroke(); return end
		if undoPos <= 0 then return end
		undoPos = undoPos-1
		workImg = Image(undoStack[undoPos])
		snapshot = Image(workImg)
		invalidatePreview()
	end

	local function redo()
		if isDrawing or undoPos >= #undoStack then return end
		undoPos = undoPos+1
		workImg = Image(undoStack[undoPos])
		snapshot = Image(workImg)
		invalidatePreview()
	end

	local function refreshPreview()
		hoverDirty = true
		if dlg then dlg:repaint() end
	end

	local function updateCanvasCursor()
		if not dlg then return end
		local cursor = MouseCursor.ARROW
		if isPanning then
			cursor = MouseCursor.GRABBING
		elseif spaceHeld then
			cursor = MouseCursor.GRAB
		elseif sourcePoint then
			cursor = MouseCursor.NONE
		end
		dlg:modify{ id="canvas", mousecursor=cursor }
	end

	dlg = Dialog{ title="Clone Stamp", notitlebar=false, resizeable=true }
	if not dlg then disposeState(); return end
	dlg
		:newrow{ always=false }
		:label{ text="Tiled Mode" }
		:label{ text="Radius" }
		:label{ text="Opacity" }
		:label{ text="Softness" }
		:slider{ id="tiled", min=0, max=3, value=tiledMode,
			onchange=function()
				finishStroke()
				local oldX, oldY = isTiledX() and 1 or 0, isTiledY() and 1 or 0
				tiledMode = boundedNumber(dlg.data.tiled, 0, 0, 3, true)
				local newX, newY = isTiledX() and 1 or 0, isTiledY() and 1 or 0
				vOffX = vOffX+(oldX-newX)*workImg.width*vScale
				vOffY = vOffY+(oldY-newY)*workImg.height*vScale
				refreshPreview()
			end }
		:slider{ id="radius", min=1, max=64, value=radius,
			onchange=function()
				finishStroke()
				radius = boundedNumber(dlg.data.radius, 16, 1, 64, true)
				savePrefs(prefs)
				refreshPreview()
			end }
		:slider{ id="opacity", min=0, max=100, value=math.floor(opacity*100+0.5),
			onchange=function()
				finishStroke()
				opacity = boundedNumber(dlg.data.opacity, 100, 0, 100, true)/100
				savePrefs(prefs)
				refreshPreview()
			end }
		:slider{ id="softness", min=0, max=100, value=math.floor(softness*100+0.5),
			onchange=function()
				finishStroke()
				softness = boundedNumber(dlg.data.softness, 50, 0, 100, true)/100
				savePrefs(prefs)
				refreshPreview()
			end }
		:newrow{ always=false }
		:canvas{ id="canvas", autoscaling=false, focus=true,
			onpaint=function(ev)
				if not workImg then return end
				local gc = ev.context
				local countX, countY = isTiledX() and 3 or 1, isTiledY() and 3 or 1
				if not centered then
					if gc.width <= 0 or gc.height <= 0 then return end
					local fit = math.min(gc.width/(workImg.width*countX), gc.height/(workImg.height*countY))
					vScale = 1
					while vScale > fit do vScale = vScale/2 end
					while vScale*2 <= fit and vScale < 32 do vScale = vScale*2 end
					minScale = math.min(0.5, vScale)
					vOffX = (gc.width-workImg.width*countX*vScale)/2
					vOffY = (gc.height-workImg.height*countY*vScale)/2
					centered = true
				end
				local s, ox, oy = vScale, vOffX, vOffY
				local wImg, hImg = workImg.width, workImg.height
				local showHover = not isDrawing and not isPanning and sourcePoint and
					mouseX >= 0 and mouseY >= 0 and mouseX < gc.width and mouseY < gc.height
				if showHover then
					local wx, wy = toWork(mouseX, mouseY)
					if hoverDirty or wx ~= stampPWX or wy ~= stampPWY then
						updateStampPreview(wx, wy, offset and offset.x or wx-sourcePoint.x,
							offset and offset.y or wy-sourcePoint.y)
					end
				end
				if not baseDisplay then baseDisplay = makeDisplayImage(workImg) end
				local src = previewDisplay or (showHover and stampPreview) or baseDisplay

				-- Draw the final result ONCE over the canvas's normal theme backing.
				-- A transparent hover reveals that same backing; no SRC clearing or
				-- extra checkerboard/control is needed, and tile wrapping matches paint.
				for ty = 0, countY-1 do
					for tx = 0, countX-1 do
						gc:drawImage(src, 0, 0, wImg, hImg,
							math.floor(tx*wImg*s+ox+0.5), math.floor(ty*hImg*s+oy+0.5),
							math.max(1, math.floor(wImg*s+0.5)), math.max(1, math.floor(hImg*s+0.5)))
					end
				end

				if countX > 1 or countY > 1 then
					gc:save()
					gc.blendMode = BlendMode.DIFFERENCE
					gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
					gc.strokeWidth = 1
					for tx = 1, countX-1 do
						local x = math.floor(tx*wImg*s+ox+0.5)
						gc:beginPath()
						gc:moveTo(x, math.floor(oy))
						gc:lineTo(x, math.floor(countY*hImg*s+oy))
						gc:stroke()
					end
					for ty = 1, countY-1 do
						local y = math.floor(ty*hImg*s+oy+0.5)
						gc:beginPath()
						gc:moveTo(math.floor(ox), y)
						gc:lineTo(math.floor(countX*wImg*s+ox), y)
						gc:stroke()
					end
					gc:restore()
				end

				if mouseX >= 0 and mouseY >= 0 and sourcePoint then
					local wx, wy = toWork(mouseX, mouseY)
					local sx, sy = offset and wx-offset.x or sourcePoint.x, offset and wy-offset.y or sourcePoint.y
					if isTiledX() then wx, sx = wx % wImg, sx % wImg end
					if isTiledY() then wy, sy = wy % hImg, sy % hImg end
					gc:save()
					gc.blendMode = BlendMode.DIFFERENCE
					gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
					for ty = 0, countY-1 do
						for tx = 0, countX-1 do
							local x, y = toCanvas(tx*wImg+wx, ty*hImg+wy)
							drawMarker(gc, x, y, radius*s)
							x, y = toCanvas(tx*wImg+sx, ty*hImg+sy)
							drawMarker(gc, x, y, radius*s, true)
						end
					end
					gc:restore()
				end

				-- Original selection-edge overlay, restricted to the visible tiles.
				if selEdgeImg then
					gc:save()
					gc.blendMode = BlendMode.DIFFERENCE
					gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
					gc.strokeWidth = 1
					for ty = 0, countY-1 do
						for tx = 0, countX-1 do
							local bx, by = tx*wImg, ty*hImg
							local x1, y1 = math.max(0, math.floor(-ox/s)-bx), math.max(0, math.floor(-oy/s)-by)
							local x2 = math.min(wImg-1, math.floor((gc.width-ox)/s)-bx)
							local y2 = math.min(hImg-1, math.floor((gc.height-oy)/s)-by)
							gc:beginPath()
							for y = y1, y2 do
								for x = x1, x2 do
									local mask = selEdgeImg:getPixel(x, y)
									if mask ~= 0 then
										local cx = math.floor((bx+x)*s+ox+0.5)
										local cy = math.floor((by+y)*s+oy+0.5)
										local cw = math.max(1, math.floor(s+0.5))
										if mask % 2 == 1 then gc:moveTo(cx, cy); gc:lineTo(cx+cw, cy) end
										if math.floor(mask/2) % 2 == 1 then gc:moveTo(cx+cw, cy); gc:lineTo(cx+cw, cy+cw) end
										if math.floor(mask/4) % 2 == 1 then gc:moveTo(cx, cy+cw); gc:lineTo(cx+cw, cy+cw) end
										if mask >= 8 then gc:moveTo(cx, cy); gc:lineTo(cx, cy+cw) end
									end
								end
							end
							gc:stroke()
						end
					end
					gc:restore()
				end
			end,
			onwheel=function(ev)
				finishStroke()

				if ev.ctrlKey then
					-- Ctrl+wheel changes clone radius.
					local delta = ev.deltaY < 0 and 1 or -1
					radius = math.max(1, math.min(64, radius+delta))
					dlg:modify{ id="radius", value=radius }
					savePrefs(prefs)

				elseif ev.shiftKey then
					-- Shift+wheel pans horizontally.
					local amount = ev.deltaY < 0 and 32 or -32
					vOffX = vOffX+amount

				elseif ev.altKey then
					-- Alt+wheel pans vertically.
					local amount = ev.deltaY < 0 and 32 or -32
					vOffY = vOffY+amount

				else
					-- Plain wheel zooms around the pointer.
					local scale = math.max(minScale, math.min(32,
						vScale*(ev.deltaY < 0 and 2 or 0.5)))
					vOffX = ev.x-(ev.x-vOffX)*(scale/vScale)
					vOffY = ev.y-(ev.y-vOffY)*(scale/vScale)
					vScale = scale
				end

				refreshPreview()
			end,
			onmousedown=function(ev)
				mouseX, mouseY = ev.x, ev.y
				if ev.button == MouseButton.MIDDLE or
				   (ev.button == MouseButton.LEFT and spaceHeld) then
					if isDrawing then return end
					isPanning = true
					panButton = ev.button
					panSX, panSY, panOX, panOY = ev.x, ev.y, vOffX, vOffY
					updateCanvasCursor()
					return
				end
				if isPanning then return end
				local wx, wy = toWork(ev.x, ev.y)
				if ev.button == MouseButton.RIGHT then
					if isDrawing then cancelStroke(); refreshPreview(); return end
					local x, y = workCoordinates(wx, wy)
					if x == nil then return end
					sourcePoint, offset = Point(x, y), nil
					snapshot = Image(workImg)
					updateCanvasCursor()
					refreshPreview()
					return
				end
				if ev.button ~= MouseButton.LEFT or isDrawing then return end
				if not sourcePoint then
					local x, y = workCoordinates(wx, wy)
					if x == nil then return end
					sourcePoint, offset = Point(x, y), nil
					snapshot = Image(workImg)
					updateCanvasCursor()
					refreshPreview()
					return
				end
				strokeOffsetBefore = offset
				if not offset then
					-- Tile copies are views of the same pixels, not different source offsets.
					local anchorX = isTiledX() and wx % workImg.width or wx
					local anchorY = isTiledY() and wy % workImg.height or wy
					offset = Point(anchorX-sourcePoint.x, anchorY-sourcePoint.y)
				end
				isDrawing, lastWX, lastWY = true, wx, wy
				ensureBrushMask()
				beginAccum()
				stampWithMask(wx, wy, offset.x, offset.y)
				updatePreview()
				dlg:repaint()
			end,
			onmousemove=function(ev)
				mouseX, mouseY = ev.x, ev.y
				if isPanning then
					vOffX, vOffY = panOX+ev.x-panSX, panOY+ev.y-panSY
					hoverDirty = true
				elseif isDrawing then
					local wx, wy = toWork(ev.x, ev.y)
					if wx ~= lastWX or wy ~= lastWY then
						stampSegment(lastWX, lastWY, wx, wy, offset.x, offset.y)
						lastWX, lastWY = wx, wy
						updatePreview()
					end
				end
				dlg:repaint()
			end,
			onmouseup=function(ev)
				mouseX, mouseY = ev.x, ev.y
				if isPanning and ev.button == panButton then
					isPanning = false
					panButton = nil
					updateCanvasCursor()
					refreshPreview()
					return
				end
				if ev.button ~= MouseButton.LEFT or not isDrawing then return end
				local wx, wy = toWork(ev.x, ev.y)
				if wx ~= lastWX or wy ~= lastWY then stampSegment(lastWX, lastWY, wx, wy, offset.x, offset.y) end
				finishStroke()
				dlg:repaint()
			end,
			onkeydown=function(ev)
				if ev.code == "Space" then
					ev:stopPropagation()
					spaceHeld = true
					updateCanvasCursor()
					return
				end
				if ev.repeatCount > 0 then return end
				if ev.code == "KeyK" and not ev.ctrlKey and not ev.metaKey and not ev.altKey then
					ev:stopPropagation()
					dlg:close()
				elseif (ev.metaKey or ev.ctrlKey) and ev.code == "KeyZ" then
					ev:stopPropagation()
					if ev.shiftKey then redo() else undo() end
					dlg:repaint()
				elseif (ev.metaKey or ev.ctrlKey) and ev.code == "KeyY" then
					ev:stopPropagation()
					redo()
					dlg:repaint()
				end
			end,
			onkeyup=function(ev)
				if ev.code == "Space" then
					ev:stopPropagation()
					spaceHeld = false
					updateCanvasCursor()
				end
			end }
		:newrow()
		:canvas{ id="applyButton",
			width=64,
			height=20,
			autoscaling=true,
			hexpand=false,
			vexpand=false,
			onpaint=function(ev)
				local gc = ev.context
				local bounds = Rectangle(0, 0, gc.width, gc.height)
				gc:drawThemeRect("button_normal", bounds)
				gc.color = app.theme.color.button_normal_text
				local size = gc:measureText("Apply")
				gc:fillText("Apply",
					math.floor((gc.width-size.width)/2),
					math.floor((gc.height-size.height)/2))
			end,
			onmousedown=function(ev)
				if ev.button ~= MouseButton.LEFT then return end
				finishStroke()
				requestedAction = "apply"
				dlg:close()
			end
		}

	-- Reopen the same dialog iteratively. Recursive onclose/show calls retain
	-- old canvases and can strand the session when the confirmation is closed.
	local function tryApply()
		local ok, err = xpcall(function()
			app.transaction("Clone Stamp", applyToCel)
		end, errorTraceback)
		if ok then
			app.refresh()
			return true
		end
		reportFailure("Changes were not applied. Your session is still available.", err)
		return false
	end

	local function initialDialogBounds()
		local width = app.window and tonumber(app.window.width) or 0
		local height = app.window and tonumber(app.window.height) or 0

		if width <= 0 or height <= 0 then
			local hint = dlg.sizeHint
			width = math.max(1, tonumber(hint.width) or 1)
			height = math.max(1, tonumber(hint.height) or 1)
		end

		return Rectangle(
			0, 0,
			math.max(1, math.floor(width)),
			math.max(1, math.floor(height)))
	end

	local function usableDialogBounds(value)
		return value ~= nil
			and type(value.x) == "number"
			and type(value.y) == "number"
			and type(value.width) == "number"
			and type(value.height) == "number"
			and value.width > 0
			and value.height > 0
	end

	local function copyDialogBounds(value)
		return Rectangle(
			value.x, value.y,
			value.width, value.height)
	end

	local bounds = initialDialogBounds()

	while not exiting do
		dlg:show{ wait=true, bounds=bounds }
		if exiting then break end

		local shownBounds = dlg.bounds
		if usableDialogBounds(shownBounds) then
			bounds = copyDialogBounds(shownBounds)
		else
			bounds = initialDialogBounds()
		end
		finishStroke()
		isPanning, panButton, spaceHeld = false, nil, false

		local action = requestedAction
		requestedAction = nil

		if action == "apply" then
			if tryApply() then break end
		else
			local x1, y1, x2, y2 = getWorkDirtyBounds()
			if x1 > x2 or y1 > y2 then break end

			local choice = app.alert{
				title="Apply changes?",
				text=tostring(undoPos).." stroke(s) made.",
				buttons={ "Apply", "Discard", "Continue Editing" }
			}

			if choice == 1 then
				if tryApply() then break end
			elseif choice == 2 then
				break
			end
		end

		-- Escape/X/K still uses the confirmation path above.
		-- Continue Editing keeps zoom, pan, source, and undo/redo intact.
	end
	dlg = nil
	disposeState()
end

-- =========================================================================
-- Extension entry points
-- =========================================================================
function init(plugin)
	exiting = false
	local prefs = plugin.preferences
	if prefs.radius == nil then prefs.radius = 16 end
	if prefs.softness == nil then prefs.softness = 0.5 end
	if prefs.spacing == nil then prefs.spacing = 0.25 end
	if prefs.opacity == nil then prefs.opacity = 1.0 end
	plugin:newCommand{ id="StampBrush_Clone", title="Clone Stamp", group="edit_fill",
		onclick=function()
			if sessionBusy then return end
			sessionBusy = true
			local ok, err = xpcall(function()
				stampBrushDialog(prefs)
			end, errorTraceback)

			sessionBusy = false
			if not ok then
				if dlg then pcall(function() dlg:close() end) end
				dlg = nil
				disposeState()
				reportFailure("Clone Stamp failed.", err)
			end
		end,
		onenabled=function()
			return not sessionBusy and app.activeSprite ~= nil and app.activeCel ~= nil
		end }
end

function exit(plugin)
	exiting = true
	savePrefs(plugin.preferences)
	if dlg then pcall(function() dlg:close() end) end
	dlg = nil
	disposeState()
end
