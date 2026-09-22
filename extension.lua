-- Clone Stamp Extension for Aseprite
-- Custom tiled canvas, pan/zoom, smoothstep brush, and max-coverage strokes.
-- workImg and snapshot use sprite-canvas coordinates; undo history stores pixel deltas.
-- Apply replaces a detached image in one native undoable transaction.
-- API: Aseprite >= 1.3 (Dialog:canvas support required).

local TILED_NONE, TILED_X, TILED_Y, TILED_BOTH = 0, 1, 2, 3

-- =========================================================================
-- Localization
-- English is built in so the extension remains usable even if a locale file
-- is missing. Additional locales override only the keys they translate.
-- =========================================================================

local uiText = {
clone_stamp = "Clone Stamp",
eraser_only = "Eraser Only",
eraser_needs_transparency = "Eraser Only requires a layer that supports transparency. Convert the Background layer to a normal layer first.",

tiled_mode = "Tiled Mode",
radius = "Radius",
opacity = "Opacity",
softness = "Softness",

apply = "Apply",
reset = "Reset",
before = "Before",
after = "After",
apply_changes = "Apply changes?",
discard = "Discard",
continue_editing = "Continue Editing",

stroke_made_one = "1 stroke made.",
strokes_made_other = "%d strokes made.",

raster_layer_required =
"Clone Stamp requires a raster image layer, not a tilemap or reference layer.",
layer_locked =
"The layer or one of its groups is locked.",
no_active_cel =
"No active cel!",
unsupported_color_mode =
"Unsupported image color mode.",
no_usable_palette =
"The active frame has no usable palette.",

active_sprite_changed =
"The active sprite changed while Clone Stamp was open. Changes were not applied.",
original_cel_missing =
"The original cel no longer exists.",
original_cel_changed =
"The original cel or canvas changed while Clone Stamp was open. Changes were not applied.",

unknown_error = "Unknown error",
full_error_report = "Full error report written to:",
error_report_failed = "Could not write the full error report.",
changes_not_applied =
"Changes were not applied. Your session is still available.",
clone_stamp_failed =
"Clone Stamp failed.",
}

local function tr(key)
return uiText[key] or key
end

local function strokeSummary(count)
if count == 1 then
return tr("stroke_made_one")
end
return string.format(tr("strokes_made_other"), count)
end

local function normalizeLocale(value)
if type(value) ~= "string" then return "en" end

value = value:lower():gsub("_", "-")
value = value:match("^%s*(.-)%s*$")

-- Locale names become filenames, so accept language-tag characters only.
if value == "" or not value:match("^[a-z][a-z0-9%-]*$") then
        return "en"
end

return value
end

local function detectLocale()
local ok, value = pcall(function()
return app.preferences.general.language
end)

if ok then
return normalizeLocale(value)
end

return "en"
end

local function loadLocale(plugin)
local locale = detectLocale()
if locale == "en" then return end

local candidates = {}
local baseLocale = locale:match("^([a-z]+)-")

-- Load the base language first so a regional translation can override only
-- the strings that differ from it.
if baseLocale and baseLocale ~= locale then
        candidates[#candidates+1] = baseLocale
end

candidates[#candidates+1] = locale

local separator = package.config:sub(1, 1)

for _, candidate in ipairs(candidates) do
        local localePath =
        plugin.path .. separator ..
        "locale" .. separator ..
        candidate .. ".lua"

        local ok, translations = pcall(dofile, localePath)

        if ok and type(translations) == "table" then
                for key, value in pairs(translations) do
                        if type(key) == "string" and type(value) == "string" then
                                uiText[key] = value
                        end
                end
        end
end
end


-- =========================================================================
-- Session state (no document pixels are modified before Apply)
-- =========================================================================
local dlg = nil
local sessionBusy, exiting = false, false
local eraserOnly = false
local radius, softness, opacity, spacing = 14, 0.67, 1.0, 0.25
local workImg, sourcePoint, offset, snapshot = nil, nil, nil, nil
local undoStack, undoPos = nil, 0
local tiledMode = TILED_NONE
local celX, celY, celColorMode = 0, 0, nil
local sessionSprite, sessionLayer, sessionFrame, sessionCel = nil, nil, nil, nil
local originalCel, originalImageId = nil, nil
local backgroundLayer, transparentIndex = false, 0
local paletteColors, paletteSize, paletteCache, paletteCacheSize = nil, 0, nil, 0
local brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1
local alphaAcc, colorAcc = nil, nil
local previewDirtyPixels = {}
local strokeDirtyPixels = {}
local sessionDirtyPixels = {}
local selMask, selBounds, selEdges = nil, nil, nil

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
    previewDirtyPixels = {}
    strokeDirtyPixels = {}
end

local function disposeState()
	eraserOnly = false
	workImg, sourcePoint, offset, snapshot = nil, nil, nil, nil
	undoStack, undoPos = nil, 0
	sessionSprite, sessionLayer, sessionFrame, sessionCel = nil, nil, nil, nil
	originalCel, originalImageId = nil, nil
	celX, celY, celColorMode = 0, 0, nil
	backgroundLayer, transparentIndex = false, 0
	paletteColors, paletteSize, paletteCache, paletteCacheSize = nil, 0, nil, 0
	brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1
	selMask, selBounds, selEdges = nil, nil, nil
	sessionDirtyPixels = {}
	resetAccum()
end

local function layerProblem(layer, sprite)
	if not layer or not layer.isImage or layer.isTilemap or layer.isReference then
		return tr("raster_layer_required")
	end
	local current = layer
	while current do
		if not current.isEditable then return tr("layer_locked") end
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

local function paletteForFrame(sprite, frameNumber)
	local chosen, chosenFrame = nil, -1
	local palettes = sprite.palettes

	-- Bound palette access explicitly: some Aseprite builds throw instead of
	-- returning nil when ipairs probes one element past the palette array.
	for index = 1, #palettes do
		local palette = palettes[index]
		local frame = palette.frame
		local number = 1

		if type(frame) == "number" then
			number = frame
		elseif frame and frame.frameNumber then
			number = frame.frameNumber
		end

		if number <= frameNumber and number >= chosenFrame then
			chosen, chosenFrame = palette, number
		end
	end

	return chosen
end

local function capturePalette(sprite, frameNumber)
	local chosen = paletteForFrame(sprite, frameNumber)
	if not chosen or #chosen == 0 then return false end
	paletteSize = math.min(256, #chosen)
	paletteColors, paletteCache, paletteCacheSize = {}, {}, 0
	for index = 0, paletteSize - 1 do
		local color = chosen:getColor(index)
		paletteColors[index] = { color.red, color.green, color.blue, color.alpha }
	end
	return true
end

local function paletteMatchesSession(sprite, frameNumber)
	local chosen = paletteForFrame(sprite, frameNumber)
	if not chosen or math.min(256, #chosen) ~= paletteSize then return false end

	for index = 0, paletteSize - 1 do
		local saved = paletteColors[index]
		local current = chosen:getColor(index)
		if not saved or
		   current.red ~= saved[1] or
		   current.green ~= saved[2] or
		   current.blue ~= saved[3] or
		   current.alpha ~= saved[4] then
			return false
		end
	end

	return true
end

local function initState(prefs)
	disposeState()
	local sprite, activeCel = app.activeSprite, app.activeCel
	if not sprite or not activeCel then return false, tr("no_active_cel") end
	local problem = layerProblem(activeCel.layer, sprite)
	if problem then return false, problem end
	local mode = activeCel.image.colorMode
	if mode ~= ColorMode.RGB and mode ~= ColorMode.GRAYSCALE and mode ~= ColorMode.INDEXED then
		return false, tr("unsupported_color_mode")
	end

	sessionSprite, sessionLayer, sessionFrame, sessionCel = sprite, activeCel.layer, activeCel.frameNumber, activeCel
	celX, celY = activeCel.position.x, activeCel.position.y
	celColorMode = mode
	backgroundLayer = sessionLayer.isBackground
	transparentIndex = sprite.transparentColor
	originalCel = Image(activeCel.image)
	originalImageId = activeCel.image.id
	if mode == ColorMode.INDEXED and not capturePalette(sprite, sessionFrame) then
		return false, tr("no_usable_palette")
	end

	radius = boundedNumber(prefs.radius, 14, 1, 64, true)
	softness = boundedNumber(prefs.softness, 0.67, 0, 1)
	opacity = boundedNumber(prefs.opacity, 1, 0, 1)
	spacing, tiledMode = 0.25, TILED_NONE

        workImg = newSessionImage(sprite.width, sprite.height)
        if app.apiVersion and app.apiVersion >= 32 then
                -- BlendMode.SRC performs a direct native copy, preserving transparent
                -- source pixels instead of alpha-compositing them over the destination.
                workImg:drawImage(
                        originalCel,
                        Point(celX, celY),
                        255,
                        BlendMode.SRC)
        else
                -- Keep the original raw-pixel path for older Aseprite API versions.
                copyPixels(originalCel, workImg, celX, celY)
        end
	snapshot = workImg
        undoStack, undoPos = { [0] = Image(workImg) }, 0
        sessionDirtyPixels = {}

	local selection = sprite.selection
	if selection and not selection.isEmpty then
	        selMask = Image(sprite.width, sprite.height, ColorMode.GRAYSCALE)
	        selMask:clear()
	        selEdges = {}
	        selBounds = selection.bounds

	        local x1 = math.max(0, selBounds.x)
	        local y1 = math.max(0, selBounds.y)
	        local x2 = math.min(
	                sprite.width-1,
	                selBounds.x+selBounds.width-1)
	        local y2 = math.min(
	                sprite.height-1,
	                selBounds.y+selBounds.height-1)

	        for y = y1, y2 do
	                for x = x1, x2 do
	                        if selection:contains(x, y) then
	                                selMask:drawPixel(x, y, 255)
	                        end
	                end
	        end

	        local function addSelectionEdge(ax, ay, bx, by)
	                local index = #selEdges+1
	                selEdges[index] = ax
	                selEdges[index+1] = ay
	                selEdges[index+2] = bx
	                selEdges[index+3] = by
	        end

	        -- Merge neighboring top/bottom edges into horizontal runs.
	        for y = y1, y2 do
	                local topStart, bottomStart = nil, nil

	                for x = x1, x2 do
	                        local selected = selMask:getPixel(x, y) ~= 0
	                        local topEdge = selected and
	                                (y == 0 or selMask:getPixel(x, y-1) == 0)
	                        local bottomEdge = selected and
	                                (y == sprite.height-1 or
	                                 selMask:getPixel(x, y+1) == 0)

	                        if topEdge then
	                                if topStart == nil then topStart = x end
	                        elseif topStart ~= nil then
	                                addSelectionEdge(topStart, y, x, y)
	                                topStart = nil
	                        end

	                        if bottomEdge then
	                                if bottomStart == nil then bottomStart = x end
	                        elseif bottomStart ~= nil then
	                                addSelectionEdge(bottomStart, y+1, x, y+1)
	                                bottomStart = nil
	                        end
	                end

	                if topStart ~= nil then
	                        addSelectionEdge(topStart, y, x2+1, y)
	                end
	                if bottomStart ~= nil then
	                        addSelectionEdge(bottomStart, y+1, x2+1, y+1)
	                end
	        end

	        -- Merge neighboring left/right edges into vertical runs.
	        for x = x1, x2 do
	                local leftStart, rightStart = nil, nil

	                for y = y1, y2 do
	                        local selected = selMask:getPixel(x, y) ~= 0
	                        local leftEdge = selected and
	                                (x == 0 or selMask:getPixel(x-1, y) == 0)
	                        local rightEdge = selected and
	                                (x == sprite.width-1 or
	                                 selMask:getPixel(x+1, y) == 0)

	                        if leftEdge then
	                                if leftStart == nil then leftStart = y end
	                        elseif leftStart ~= nil then
	                                addSelectionEdge(x, leftStart, x, y)
	                                leftStart = nil
	                        end

	                        if rightEdge then
	                                if rightStart == nil then rightStart = y end
	                        elseif rightStart ~= nil then
	                                addSelectionEdge(x+1, rightStart, x+1, y)
	                                rightStart = nil
	                        end
	                end

	                if leftStart ~= nil then
	                        addSelectionEdge(x, leftStart, x, y2+1)
	                end
	                if rightStart ~= nil then
	                        addSelectionEdge(x+1, rightStart, x+1, y2+1)
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

local function erasePixel(destination, coverage)
	if coverage <= 0 or backgroundLayer then return destination end

	-- Indexed images cannot store per-pixel partial alpha. Keep the existing
	-- binary transparent-index rule used elsewhere in the extension.
	if celColorMode == ColorMode.INDEXED then
		return coverage > 127 and transparentIndex or destination
	end

	local red, green, blue, alpha = pixelRGBA(destination)
	local outAlpha = math.floor(alpha*(255-coverage)/255 + 0.5)

	if celColorMode == ColorMode.GRAYSCALE then
		return app.pixelColor.graya(red, outAlpha)
	end

	return app.pixelColor.rgba(red, green, blue, outAlpha)
end

local function makeDisplayImage(image)
	if celColorMode == ColorMode.RGB then return image end
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
local function updateSessionDirtyPixel(x, y, value)
local original = undoStack and undoStack[0]
if not original or not workImg then return end

local key = y*workImg.width+x

if value ~= original:getPixel(x, y) then
sessionDirtyPixels[key] = true
else
sessionDirtyPixels[key] = nil
end
end

local function getWorkDirtyBounds()
if not workImg or next(sessionDirtyPixels) == nil then
return 0, 0, -1, -1
end

local x1, y1 = workImg.width, workImg.height
local x2, y2 = -1, -1

for key in pairs(sessionDirtyPixels) do
local x = key % workImg.width
local y = math.floor(key/workImg.width)

x1, y1 = math.min(x1, x), math.min(y1, y)
x2, y2 = math.max(x2, x), math.max(y2, y)
end

return x1, y1, x2, y2
end

local function validateSession()
	local spriteOk, sameSprite = pcall(function()
		return sessionSprite and app.activeSprite and
		       app.activeSprite.id == sessionSprite.id
	end)
	if not spriteOk or not sameSprite then
		return tr("active_sprite_changed")
	end

	local celOk, activeCel = pcall(function()
		return sessionLayer and sessionLayer:cel(sessionFrame) or nil
	end)
	if not celOk or not activeCel then return tr("original_cel_missing") end
	if activeCel ~= sessionCel then return tr("original_cel_changed") end

	local problem = layerProblem(sessionLayer, sessionSprite)
	if problem then return problem end

	if sessionSprite.width ~= workImg.width or
	   sessionSprite.height ~= workImg.height or
	   activeCel.position.x ~= celX or
	   activeCel.position.y ~= celY or
	   sessionLayer.isBackground ~= backgroundLayer or
	   activeCel.image.id ~= originalImageId or
	   not activeCel.image:isEqual(originalCel) then
		return tr("original_cel_changed")
	end

	if celColorMode == ColorMode.INDEXED then
		if (not backgroundLayer and
		    sessionSprite.transparentColor ~= transparentIndex) or
		   not paletteMatchesSession(sessionSprite, sessionFrame) then
			return tr("original_cel_changed")
		end
	end

	return nil
end

local function applyToCel(x1, y1, x2, y2)
	local activeCel = sessionLayer:cel(sessionFrame)
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
	-- Publish the mask and its cache keys only after the complete build succeeds.
	local nextMask = Image(radius*2+1, radius*2+1, ColorMode.GRAYSCALE)
	nextMask:clear()
	local inner = radius*(1-softness)
	for dy = -radius, radius do
		for dx = -radius, radius do
			local distance, value = math.sqrt(dx*dx+dy*dy), 0
			if distance < radius then
				if softness <= 0 or distance <= inner then value = 1
				else value = 1-smoothstep((distance-inner)/(radius-inner)) end
			end
			nextMask:drawPixel(dx+radius, dy+radius, math.floor(value*opacity*255+0.5))
		end
	end
	brushMask = nextMask
	brushMaskR, brushMaskS, brushMaskO = radius, softness, opacity
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

local function forMaskPixels(cx, cy, visit)
	local r = brushMaskR
	for my = 0, brushMask.height-1 do
		for mx = 0, brushMask.width-1 do
			local coverage = brushMask:getPixel(mx, my)
			if coverage > 0 then
				local x, y = workCoordinates(cx+mx-r, cy+my-r)
				if x ~= nil and (not selMask or selMask:getPixel(x, y) ~= 0) then
					visit(x, y, coverage)
				end
			end
		end
	end
end

local function forBrushPixels(cx, cy, offX, offY, visit)
	forMaskPixels(cx, cy, function(x, y, coverage)
		local source = sampleSource(x, y, offX, offY)
		if source ~= nil then visit(x, y, source, coverage) end
	end)
end

local function beginAccum()
	alphaAcc = Image(workImg.width, workImg.height, ColorMode.GRAYSCALE)
	alphaAcc:clear()
	colorAcc = nil
	if not eraserOnly then colorAcc = newSessionImage(workImg.width, workImg.height) end
    previewDirtyPixels = {}
    strokeDirtyPixels = {}
end

local function stampWithMask(cx, cy, offX, offY)
	forBrushPixels(cx, cy, offX, offY, function(x, y, source, coverage)
		if alphaAcc:getPixel(x, y) >= coverage then return end
		alphaAcc:drawPixel(x, y, coverage)
		colorAcc:drawPixel(x, y, source)
            local key = y*workImg.width+x
            previewDirtyPixels[key] = true
            strokeDirtyPixels[key] = true
	end)
end

local function eraseWithMask(cx, cy)
	forMaskPixels(cx, cy, function(x, y, coverage)
		if alphaAcc:getPixel(x, y) >= coverage then return end
		alphaAcc:drawPixel(x, y, coverage)
            local key = y*workImg.width+x
            previewDirtyPixels[key] = true
            strokeDirtyPixels[key] = true
	end)
end

local function paintWithMask(cx, cy, offX, offY)
	if eraserOnly then
		eraseWithMask(cx, cy)
	else
		stampWithMask(cx, cy, offX, offY)
	end
end

local function commitAccumToWork()
    if not alphaAcc or next(strokeDirtyPixels) == nil then return nil end

    local delta = {}

    for key in pairs(strokeDirtyPixels) do
        local x = key % workImg.width
        local y = math.floor(key/workImg.width)
        local coverage = alphaAcc:getPixel(x, y)
        local current = workImg:getPixel(x, y)
        local result

        if eraserOnly then
            result = erasePixel(current, coverage)
        else
            result = blendPixel(
                colorAcc:getPixel(x, y),
                current,
                coverage)
        end

        if result ~= current then
            local index = #delta+1
            delta[index] = x
            delta[index+1] = y
            delta[index+2] = current
            delta[index+3] = result
            workImg:drawPixel(x, y, result)
            updateSessionDirtyPixel(x, y, result)
        end
    end

    if #delta == 0 then return nil end
    return delta
end

local function paintSegment(x1, y1, x2, y2, offX, offY)
	local step = math.max(1, math.floor(brushMaskR*spacing))
	local dx, dy = x2-x1, y2-y1
	local count = math.max(1, math.ceil(math.sqrt(dx*dx+dy*dy)/step))
	for i = 1, count do
		local t = i/count
		paintWithMask(math.floor(x1+dx*t+0.5), math.floor(y1+dy*t+0.5), offX, offY)
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

local function drawMarker(gc, x, y, r, highContrast, innerColor)
	if highContrast then
		gc:save()
		gc.blendMode = BlendMode.NORMAL

		-- Shared dark outer stroke keeps both markers visible over varied artwork.
		gc.strokeWidth = 3
		gc.color = Color{ red=32, green=32, blue=32, alpha=255 }
		markerPath(gc, x, y, r)
		gc:stroke()

		gc.strokeWidth = 1
		gc.color = innerColor or Color{ red=200, green=200, blue=200, alpha=255 }
		markerPath(gc, x, y, r)
		gc:stroke()

		gc:restore()
	else
		gc.strokeWidth = 1
		markerPath(gc, x, y, r)
		gc:stroke()
	end
end

local function drawGuideLine(gc, x1, y1, x2, y2, aligned)
        gc:save()
        gc.blendMode = BlendMode.NORMAL

        gc.strokeWidth = 3
        gc.color = Color{ red=32, green=32, blue=32, alpha=255 }
        gc:beginPath()
        gc:moveTo(x1, y1)
        gc:lineTo(x2, y2)
        gc:stroke()

        gc.strokeWidth = 1
        if aligned then
                gc.color = Color{ red=57, green=255, blue=20, alpha=255 }
        else
                gc.color = Color{ red=200, green=200, blue=200, alpha=255 }
        end
        gc:beginPath()
        gc:moveTo(x1, y1)
        gc:lineTo(x2, y2)
        gc:stroke()

        gc:restore()
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

local function reportFailure(message, err, buttons)
	local report = tostring(err)
	local separator = package.config:sub(1, 1)
	local tempPath = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "."
	local errorPath = tempPath .. separator .. "stamp-brush-error.txt"
	local errorFile = nil

	-- Aseprite throws when file access is denied. Reporting must never replace
	-- the original error or tear down a recoverable session.
	local writeOk, reportWritten = pcall(function()
		if not io or not io.open then return false end
		errorFile = io.open(errorPath, "wb")
		if not errorFile then return false end
		local written = errorFile:write(report, report:sub(-1) == "\n" and "" or "\n")
		local closed = errorFile:close()
		errorFile = nil
		return not not written and not not closed
	end)
	if errorFile then pcall(function() errorFile:close() end) end
	reportWritten = writeOk and reportWritten == true

	-- The first nonempty line is the error; later lines are stack frames.
	local summary = report:match("[^\r\n]+") or tr("unknown_error")
	summary = summary:match("^%s*(.-)%s*$")
	summary = summary:match("^.-:%d+:%s*(.*)$") or summary
	if summary == "" then summary = tr("unknown_error") end
	if #summary > 120 then
		local lastByte = 117
		-- Do not split a UTF-8 character in a localized message or file path.
		while lastByte > 0 do
			local nextByte = summary:byte(lastByte + 1)
			if not nextByte or nextByte < 128 or nextByte >= 192 then break end
			lastByte = lastByte - 1
		end
		summary = summary:sub(1, lastByte) .. "..."
	end

	local lines = { message, summary }
	if reportWritten then
		table.insert(lines, "")
		table.insert(lines, tr("full_error_report"))
		table.insert(lines, errorPath)
	else
		table.insert(lines, "")
		table.insert(lines, tr("error_report_failed"))
		-- Preserve the full traceback in the console when a file is unavailable.
		pcall(print, report)
	end

	return app.alert{
		title=tr("clone_stamp"),
		text=lines,
		buttons=buttons
	}
end

local function stampBrushDialog(prefs)
local panDisplayCache = nil
local panDisplaySourceId = nil
local panDisplaySourceVersion = nil
local panDisplayScale = nil
local panDisplayWidth, panDisplayHeight = 0, 0

-- Avoid retaining enormous pre-scaled images at extreme zoom levels.
local panDisplayCacheMaxPixels = 16000000
	local ready, reason = initState(prefs)
	if not ready then disposeState(); app.alert(reason); return end
	local isDrawing, isPanning, spaceHeld = false, false, false
	local panButton, requestedAction = nil, nil
	local callbackError = nil
	local applyPressed, eraserPressed, beforePressed, resetPressed = false, false, false, false
	local footerWidth, footerHeight = 256, 20
	local actionButtonWidth, eraserButtonWidth = 64, 96
	local showBefore = false
	local canvasWidth, canvasHeight = 0, 0
	local magnifierActive = false
	local magnifierScale, magnifierOffX, magnifierOffY = nil, nil, nil
	local destinationLocked = false
	local mouseX, mouseY = -1, -1
	local lastWX, lastWY, strokeOffsetBefore = nil, nil, nil
	local previewDisplay, baseDisplay, beforeDisplay, stampPreview = nil, nil, nil, nil
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

	local function zoomViewAt(x, y, factor)
		local scale = math.max(minScale, math.min(32, vScale*factor))
		if scale == vScale then return end
		vOffX = x-(x-vOffX)*(scale/vScale)
		vOffY = y-(y-vOffY)*(scale/vScale)
		vScale = scale
	end

	local function hoveredPixelText()
		if canvasWidth <= 0 or canvasHeight <= 0 or
		   mouseX < 0 or mouseY < 0 or
		   mouseX >= canvasWidth or mouseY >= canvasHeight then
			return "—    X: —  Y: —"
		end

		local wx, wy = toWork(mouseX, mouseY)
		local x, y = workCoordinates(wx, wy)
		if x == nil then return "—    X: —  Y: —" end

		local sampleImage = showBefore and undoStack[0] or workImg
		local pixel = sampleImage:getPixel(x, y)

		if celColorMode == ColorMode.RGB then
			local r, g, b, a = pixelRGBA(pixel)
			return string.format(
				"R%d G%d B%d  #%02X%02X%02X  A%d    X: %d  Y: %d",
				r, g, b, r, g, b, a, x, y)
		elseif celColorMode == ColorMode.GRAYSCALE then
			local pc = app.pixelColor
			local value = pc.grayaV(pixel)
			local alpha = backgroundLayer and 255 or pc.grayaA(pixel)
			return string.format(
				"GRAY V%d  A%d    X: %d  Y: %d",
				value, alpha, x, y)
		end

		local index = pixel
		local color = paletteColors and paletteColors[index]
		local r, g, b, a

		if color then
			r, g, b = color[1], color[2], color[3]

			if not backgroundLayer and index == transparentIndex then
				a = 0
			else
				a = backgroundLayer and 255 or color[4]
			end
		else
			r, g, b, a = pixelRGBA(pixel)
		end

		return string.format(
			"IDX%d  R%d G%d B%d  #%02X%02X%02X  A%d    X: %d  Y: %d",
			index, r, g, b, r, g, b, a, x, y)
	end

	local function invalidatePreview()
		previewDisplay, baseDisplay, stampPreview = nil, nil, nil
		hoverPixels, hoverDirty = {}, true
		stampPWX, stampPWY = nil, nil
	end

	local function updateStampPreview(wx, wy, offX, offY)
		if not eraserOnly and (offX == nil or offY == nil) then stampPreview = nil; return end
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

		local function previewPixel(x, y, coverage, source)
			local key = y*workImg.width+x
			if (hoverPixels[key] or 0) >= coverage then return end
			hoverPixels[key] = coverage
			local current = workImg:getPixel(x, y)
			local result = eraserOnly and erasePixel(current, coverage) or blendPixel(source, current, coverage)
			local r, g, b, a = pixelRGBA(result)
			stampPreview:drawPixel(x, y, app.pixelColor.rgba(r, g, b, a))
		end

		if eraserOnly then
			forMaskPixels(wx, wy, function(x, y, coverage)
				previewPixel(x, y, coverage, nil)
			end)
		else
			forBrushPixels(wx, wy, offX, offY, function(x, y, source, coverage)
				previewPixel(x, y, coverage, source)
			end)
		end

		stampPWX, stampPWY, hoverDirty = wx, wy, false
	end

	local function updatePreview()
	        if not alphaAcc or next(previewDirtyPixels) == nil then return end

	        -- Copy the full display only once per stroke. Mouse movement then
	        -- patches only accumulator pixels whose coverage actually changed.
	        if not baseDisplay then baseDisplay = makeDisplayImage(workImg) end
	        if not previewDisplay then previewDisplay = Image(baseDisplay) end

	        for key in pairs(previewDirtyPixels) do
	                local x = key % workImg.width
	                local y = math.floor(key/workImg.width)
	                local coverage = alphaAcc:getPixel(x, y)

	                local current = workImg:getPixel(x, y)
	                local result
	                if eraserOnly then
	                        result = erasePixel(current, coverage)
	                else
	                        result = blendPixel(
	                                colorAcc:getPixel(x, y),
	                                current,
	                                coverage)
	                end

	                local r, g, b, a = pixelRGBA(result)
	                previewDisplay:drawPixel(
	                        x, y,
	                        app.pixelColor.rgba(r, g, b, a))
	        end

	        previewDirtyPixels = {}
	end



	local function patchDisplayDelta(display, delta)
	        if not display or not delta then return end
	        for i = 1, #delta, 4 do
	                local r, g, b, a = pixelRGBA(delta[i+3])
	                display:drawPixel(
	                        delta[i],
	                        delta[i+1],
	                        app.pixelColor.rgba(r, g, b, a))
	        end
	end

	local function finishStrokePreview(delta)
	        if delta then
	                -- previewDisplay already contains almost the entire final stroke.
	                -- Patch the mouse-up tail, then promote it to the new base display.
	                if previewDisplay then
	                        patchDisplayDelta(previewDisplay, delta)
	                        baseDisplay = previewDisplay
	                elseif baseDisplay then
	                        patchDisplayDelta(baseDisplay, delta)
	                else
	                        baseDisplay = makeDisplayImage(workImg)
	                end
	        end

	        -- Restore the retained hover footprint even when the stroke changed
	        -- no pixels. Otherwise stale hover pixels can survive a no-op stroke.
	        if stampPreview and baseDisplay then
	                for key in pairs(hoverPixels) do
	                        local x = key % workImg.width
	                        local y = math.floor(key/workImg.width)
	                        stampPreview:drawPixel(
	                                x, y,
	                                baseDisplay:getPixel(x, y))
	                end

	                if delta then
	                        for i = 1, #delta, 4 do
	                                local x, y = delta[i], delta[i+1]
	                                stampPreview:drawPixel(
	                                        x, y,
	                                        baseDisplay:getPixel(x, y))
	                        end
	                end
	        end

	        previewDisplay = nil
	        hoverPixels = {}
	        hoverDirty = true
	        stampPWX, stampPWY = nil, nil
	end

	local function applyHistoryDelta(destination, delta, useAfter)
	        local valueOffset = useAfter and 3 or 2

	        for i = 1, #delta, 4 do
	                local x = delta[i]
	                local y = delta[i+1]
	                local value = delta[i+valueOffset]

	                destination:drawPixel(x, y, value)
	                updateSessionDirtyPixel(x, y, value)
	        end
	end

	local function pushUndo(delta)
	        local nextPos = undoPos+1
	        for i = nextPos, #undoStack do undoStack[i] = nil end
	        undoStack[nextPos], undoPos = delta, nextPos
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
	        local delta = commitAccumToWork()
	        if delta then pushUndo(delta) else offset = strokeOffsetBefore end
	        snapshot = workImg
	        isDrawing = false
	        lastWX, lastWY, strokeOffsetBefore = nil, nil, nil
	        finishStrokePreview(delta)
	        resetAccum()
	end

	local function undo()
	        if isDrawing then cancelStroke(); return end
	        if undoPos <= 0 then return end
	        applyHistoryDelta(workImg, undoStack[undoPos], false)
	        undoPos = undoPos-1
	        snapshot = workImg
	        invalidatePreview()
	end

	local function redo()
	        if isDrawing or undoPos >= #undoStack then return end
	        local nextPos = undoPos+1
	        applyHistoryDelta(workImg, undoStack[nextPos], true)
	        undoPos = nextPos
	        snapshot = workImg
	        invalidatePreview()
	end

	local function refreshPreview()
		hoverDirty = true
		if dlg then dlg:repaint() end
	end


	local function resetToStart()
		if isDrawing then cancelStroke() end
		if undoPos > 0 then
			-- Allocate first so a failed copy cannot move the history position.
			local nextWork = Image(undoStack[0])
			undoPos = 0
			workImg, snapshot = nextWork, nextWork
			sessionDirtyPixels = {}
			invalidatePreview()
		end
		refreshPreview()
	end

	local function updateCanvasCursor()
		if not dlg then return end
		local cursor = MouseCursor.ARROW
		if isPanning then
			cursor = MouseCursor.GRABBING
		elseif spaceHeld then
			cursor = MouseCursor.GRAB
		elseif not showBefore and (eraserOnly or sourcePoint) then
			cursor = MouseCursor.NONE
		end
		dlg:modify{ id="canvas", mousecursor=cursor }
	end

	local function startMagnifier()
		if magnifierActive or isDrawing or isPanning then return end
		magnifierScale, magnifierOffX, magnifierOffY = vScale, vOffX, vOffY
		magnifierActive = true

		local x, y = mouseX, mouseY
		if canvasWidth <= 0 or canvasHeight <= 0 or
		   x < 0 or y < 0 or x >= canvasWidth or y >= canvasHeight then
			x, y = canvasWidth/2, canvasHeight/2
		end

		-- Two normal zoom steps (4x) make C an immediate detail view.
		zoomViewAt(x, y, 4)
		refreshPreview()
	end

	local function stopMagnifier(repaint)
		if not magnifierActive then return end
		-- Finish/cancel transient pointer state before restoring the saved view so
		-- a held mouse gesture cannot continue from temporary-view coordinates.
		if isDrawing then finishStroke() end
		isPanning, panButton = false, nil
		vScale, vOffX, vOffY = magnifierScale, magnifierOffX, magnifierOffY
		magnifierActive = false
		magnifierScale, magnifierOffX, magnifierOffY = nil, nil, nil
		hoverDirty = true
		updateCanvasCursor()
		if repaint ~= false and dlg then dlg:repaint() end
	end


	local function syncSpaceKey(ev)
		-- Mouse events reflect the current key state even if focus changed and
		-- this canvas never received the corresponding Space key-up/down.
		if type(ev.spaceKey) == "boolean" and spaceHeld ~= ev.spaceKey then
			spaceHeld = ev.spaceKey
			updateCanvasCursor()
		end
	end

	local function guardCallback(callback)
		return function(ev)
			if exiting or callbackError then return end
			-- Aseprite catches callback errors itself, so the outer command's
			-- xpcall cannot see them. Defer recovery until the dialog is closed.
			local ok, err = xpcall(callback, errorTraceback, ev)
			if not ok then
				callbackError = err
				if dlg then dlg:close() end
			end
		end
	end

	local function guardedWidget(options)
		for _, name in ipairs{
			"onchange", "onpaint", "onwheel", "onmousedown", "onmousemove",
			"onmouseup", "onkeydown", "onkeyup"
		} do
			if options[name] then options[name] = guardCallback(options[name]) end
		end
		return options
	end

	local function insideFooterButton(ev, x, width)
		return ev.x >= x and ev.y >= 0 and
		       ev.x < x+width and ev.y < footerHeight
	end

	dlg = Dialog{ title=tr("clone_stamp"), notitlebar=false, resizeable=true }
	if not dlg then disposeState(); return end
	dlg
		:newrow{ always=false }
		:label{ text=tr("tiled_mode") }
		:label{ text=tr("radius") }
		:label{ text=tr("opacity") }
		:label{ text=tr("softness") }
		:slider(guardedWidget{ id="tiled", min=0, max=3, value=tiledMode,
			onchange=function()
				finishStroke()
				local oldX, oldY = isTiledX() and 1 or 0, isTiledY() and 1 or 0
				tiledMode = boundedNumber(dlg.data.tiled, 0, 0, 3, true)
				local newX, newY = isTiledX() and 1 or 0, isTiledY() and 1 or 0
				vOffX = vOffX+(oldX-newX)*workImg.width*vScale
				vOffY = vOffY+(oldY-newY)*workImg.height*vScale
				refreshPreview()
			end })
		:slider(guardedWidget{ id="radius", min=1, max=64, value=radius,
			onchange=function()
				finishStroke()
				radius = boundedNumber(dlg.data.radius, 14, 1, 64, true)
				savePrefs(prefs)
				refreshPreview()
			end })
		:slider(guardedWidget{ id="opacity", min=0, max=100, value=math.floor(opacity*100+0.5),
			onchange=function()
				finishStroke()
				opacity = boundedNumber(dlg.data.opacity, 100, 0, 100, true)/100
				savePrefs(prefs)
				refreshPreview()
			end })
		:slider(guardedWidget{ id="softness", min=0, max=100, value=math.floor(softness*100+0.5),
			onchange=function()
				finishStroke()
				softness = boundedNumber(dlg.data.softness, 67, 0, 100, true)/100
				savePrefs(prefs)
				refreshPreview()
			end })
		:newrow{ always=false }
		:canvas(guardedWidget{ id="canvas", autoscaling=false, focus=true,
			onpaint=function(ev)
				if not workImg then return end
				local gc = ev.context
				canvasWidth, canvasHeight = gc.width, gc.height
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
				local showHover = not showBefore and not isDrawing and not isPanning and
					(eraserOnly or sourcePoint) and
					mouseX >= 0 and mouseY >= 0 and mouseX < gc.width and mouseY < gc.height
				if showHover then
					local wx, wy = toWork(mouseX, mouseY)
					if hoverDirty or wx ~= stampPWX or wy ~= stampPWY then
						if eraserOnly then
							updateStampPreview(wx, wy, nil, nil)
						else
							updateStampPreview(wx, wy, offset and offset.x or wx-sourcePoint.x,
								offset and offset.y or wy-sourcePoint.y)
						end
					end
				end
				local src
				if showBefore then
				        if not beforeDisplay then
				                beforeDisplay = makeDisplayImage(undoStack[0])
				        end
				        src = beforeDisplay
				else
				        if not baseDisplay then baseDisplay = makeDisplayImage(workImg) end
				        src = previewDisplay or (showHover and stampPreview) or baseDisplay
				end

				-- Draw the final result ONCE over the canvas's normal theme backing.
				-- A transparent hover reveals that same backing; no SRC clearing or
				-- extra checkerboard/control is needed, and tile wrapping matches paint.
				if isPanning then
				        local scaledWidth =
				                math.max(1, math.floor(wImg*s+0.5))
				        local scaledHeight =
				                math.max(1, math.floor(hImg*s+0.5))

				        -- At 1:1 there is nothing to pre-scale. Use the inexpensive
				        -- original-size draw directly.
				        if scaledWidth == wImg and scaledHeight == hImg then
				                for ty = 0, countY-1 do
				                        for tx = 0, countX-1 do
				                                gc:drawImage(
				                                        src,
				                                        math.floor(tx*wImg*s+ox+0.5),
				                                        math.floor(ty*hImg*s+oy+0.5))
				                        end
				                end
				        elseif scaledWidth*scaledHeight <= panDisplayCacheMaxPixels then
				                local sourceId = src.id
				                local sourceVersion = src.version

				                -- Rebuild only when the pixels or zoom actually changed.
				                if panDisplayCache == nil or
				                   panDisplaySourceId ~= sourceId or
				                   panDisplaySourceVersion ~= sourceVersion or
				                   panDisplayScale ~= s or
				                   panDisplayWidth ~= scaledWidth or
				                   panDisplayHeight ~= scaledHeight then
				                        panDisplayCache = Image(src)
				                        panDisplayCache:resize(
				                                scaledWidth,
				                                scaledHeight)

				                        panDisplaySourceId = sourceId
				                        panDisplaySourceVersion = sourceVersion
				                        panDisplayScale = s
				                        panDisplayWidth = scaledWidth
				                        panDisplayHeight = scaledHeight
				                end

				                -- Moving an already-scaled bitmap is much cheaper than asking
				                -- GraphicsContext to rescale the full image every mouse event.
				                for ty = 0, countY-1 do
				                        for tx = 0, countX-1 do
				                                gc:drawImage(
				                                        panDisplayCache,
				                                        math.floor(tx*wImg*s+ox+0.5),
				                                        math.floor(ty*hImg*s+oy+0.5))
				                        end
				                end
				        else
				                -- Fall back to direct scaling rather than allocating a huge
				                -- cached bitmap at very high zoom levels.
				                for ty = 0, countY-1 do
				                        for tx = 0, countX-1 do
				                                gc:drawImage(
				                                        src, 0, 0, wImg, hImg,
				                                        math.floor(tx*wImg*s+ox+0.5),
				                                        math.floor(ty*hImg*s+oy+0.5),
				                                        scaledWidth,
				                                        scaledHeight)
				                        end
				                end
				        end
				else
				        for ty = 0, countY-1 do
				                for tx = 0, countX-1 do
				                        gc:drawImage(
				                                src, 0, 0, wImg, hImg,
				                                math.floor(tx*wImg*s+ox+0.5),
				                                math.floor(ty*hImg*s+oy+0.5),
				                                math.max(1, math.floor(wImg*s+0.5)),
				                                math.max(1, math.floor(hImg*s+0.5)))
				                end
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

				if not showBefore and mouseX >= 0 and mouseY >= 0 and
				   (eraserOnly or sourcePoint) then
					local wx, wy = toWork(mouseX, mouseY)
					local sx, sy = nil, nil
					if not eraserOnly then
						sx = offset and wx-offset.x or sourcePoint.x
						sy = offset and wy-offset.y or sourcePoint.y
					end
					if isTiledX() then
						wx = wx % wImg
						if sx ~= nil then sx = sx % wImg end
					end
					if isTiledY() then
						wy = wy % hImg
						if sy ~= nil then sy = sy % hImg end
					end
					gc:save()
					gc.blendMode = BlendMode.DIFFERENCE
					gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
					for ty = 0, countY-1 do
						for tx = 0, countX-1 do
							local dx, dy = toCanvas(tx*wImg+wx, ty*hImg+wy)
							if eraserOnly then
								drawMarker(gc, dx, dy, radius*s, true,
									Color{ red=230, green=201, blue=106, alpha=255 })
							else
								local sxCanvas, syCanvas = toCanvas(tx*wImg+sx, ty*hImg+sy)
								if not destinationLocked then
									drawGuideLine(gc, sxCanvas, syCanvas, dx, dy, wx == sx or wy == sy)
								end
								drawMarker(gc, dx, dy, radius*s, true,
									Color{ red=230, green=201, blue=106, alpha=255 })
								drawMarker(gc, sxCanvas, syCanvas, radius*s, true)
							end
						end
					end
					gc:restore()
				end

				-- The selection is frozen for this session, so its merged edge runs
				-- can be transformed directly instead of searching the image each repaint.
				if selEdges and #selEdges > 0 then
				        gc:save()
				        gc.blendMode = BlendMode.DIFFERENCE
				        gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
				        gc.strokeWidth = 1

				        for ty = 0, countY-1 do
				                for tx = 0, countX-1 do
				                        local bx, by = tx*wImg, ty*hImg

				                        gc:beginPath()

				                        for i = 1, #selEdges, 4 do
				                                local ax = math.floor(
				                                        (bx+selEdges[i])*s+ox+0.5)
				                                local ay = math.floor(
				                                        (by+selEdges[i+1])*s+oy+0.5)
				                                local ex = math.floor(
				                                        (bx+selEdges[i+2])*s+ox+0.5)
				                                local ey = math.floor(
				                                        (by+selEdges[i+3])*s+oy+0.5)

				                                gc:moveTo(ax, ay)
				                                gc:lineTo(ex, ey)
				                        end

				                        gc:stroke()
				                end
				        end

				        gc:restore()
				end
			end,
			onwheel=function(ev)
				-- Horizontal-only/zero wheel events must not zoom out or shrink
				-- the brush, and must not prematurely finish a stroke.
				if ev.deltaY == 0 then return end
				mouseX, mouseY = ev.x, ev.y
				finishStroke()

				if magnifierActive then
					-- Wheel belongs to the disposable magnified view while C is held.
					zoomViewAt(ev.x, ev.y, ev.deltaY < 0 and 2 or 0.5)

				elseif ev.ctrlKey then
					-- Ctrl+wheel changes brush radius outside magnifier mode.
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
					zoomViewAt(ev.x, ev.y, ev.deltaY < 0 and 2 or 0.5)
				end

				refreshPreview()
			end,
			onmousedown=function(ev)
				syncSpaceKey(ev)
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
				if showBefore then return end
				local wx, wy = toWork(ev.x, ev.y)
				if ev.button == MouseButton.RIGHT then
					if isDrawing then cancelStroke(); refreshPreview(); return end
					if eraserOnly then return end
					local x, y = workCoordinates(wx, wy)
					if x == nil then return end
					sourcePoint, offset = Point(x, y), nil
					destinationLocked = false
					snapshot = workImg
					updateCanvasCursor()
					refreshPreview()
					return
				end
				if ev.button ~= MouseButton.LEFT or isDrawing then return end
				if eraserOnly then
					strokeOffsetBefore = offset
					isDrawing, lastWX, lastWY = true, wx, wy
					ensureBrushMask()
					beginAccum()
					paintWithMask(wx, wy, nil, nil)
					updatePreview()
					dlg:repaint()
					return
				end
				if not sourcePoint then
					local x, y = workCoordinates(wx, wy)
					if x == nil then return end
					sourcePoint, offset = Point(x, y), nil
					destinationLocked = false
					snapshot = workImg
					updateCanvasCursor()
					refreshPreview()
					return
				end
				if not offset then
					-- Tile copies are views of the same pixels, not different source offsets.
					local anchorX = isTiledX() and wx % workImg.width or wx
					local anchorY = isTiledY() and wy % workImg.height or wy
					offset = Point(anchorX-sourcePoint.x, anchorY-sourcePoint.y)
					destinationLocked = true
				end
				strokeOffsetBefore = offset
				isDrawing, lastWX, lastWY = true, wx, wy
				ensureBrushMask()
				beginAccum()
				paintWithMask(wx, wy, offset.x, offset.y)
				updatePreview()
				dlg:repaint()
			end,
			onmousemove=function(ev)
				syncSpaceKey(ev)
				mouseX, mouseY = ev.x, ev.y
				if isPanning then
					vOffX, vOffY = panOX+ev.x-panSX, panOY+ev.y-panSY
					hoverDirty = true
				elseif isDrawing then
					local wx, wy = toWork(ev.x, ev.y)
					if wx ~= lastWX or wy ~= lastWY then
						paintSegment(lastWX, lastWY, wx, wy,
							offset and offset.x or nil, offset and offset.y or nil)
						lastWX, lastWY = wx, wy
						updatePreview()
					end
				end
				dlg:repaint()
			end,
			onmouseup=function(ev)
				syncSpaceKey(ev)
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
				if wx ~= lastWX or wy ~= lastWY then
					paintSegment(lastWX, lastWY, wx, wy,
						offset and offset.x or nil, offset and offset.y or nil)
				end
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
				if ev.code == "KeyC" and not ev.ctrlKey and not ev.shiftKey and
				   not ev.altKey and not ev.metaKey then
					-- Plain C owns temporary magnification while the canvas has focus.
					ev:stopPropagation()
					if ev.repeatCount == 0 then startMagnifier() end
					return
				end
				if ev.repeatCount > 0 then return end
				if ev.code == "KeyK" and not ev.ctrlKey and not ev.metaKey and not ev.altKey then
					ev:stopPropagation()
					dlg:close()
				elseif (ev.metaKey or ev.ctrlKey) and ev.code == "KeyZ" then
				        ev:stopPropagation()
				        if not showBefore then
				                if ev.shiftKey then redo() else undo() end
				                dlg:repaint()
				        end
				elseif (ev.metaKey or ev.ctrlKey) and ev.code == "KeyY" then
				        ev:stopPropagation()
				        if not showBefore then
				                redo()
				                dlg:repaint()
				        end
				end
			end,
			onkeyup=function(ev)
				if ev.code == "Space" then
					ev:stopPropagation()
					spaceHeld = false
					updateCanvasCursor()
				elseif magnifierActive and ev.code == "KeyC" then
					ev:stopPropagation()
					stopMagnifier()
				end
			end })
		:newrow()
		:canvas(guardedWidget{ id="actionFooter",
		        width=256,
		        height=20,
		        autoscaling=true,
		        hexpand=true,
		        vexpand=false,
		        onpaint=function(ev)
		                local gc = ev.context
		                footerWidth, footerHeight = gc.width, gc.height

		                local eraserX = actionButtonWidth
		                local eraserRight = eraserX+eraserButtonWidth
		                local beforeX = eraserRight
		                local beforeRight = beforeX+actionButtonWidth
		                local resetX = math.max(beforeRight, gc.width-actionButtonWidth)

		                local applyBounds = Rectangle(0, 0, actionButtonWidth, gc.height)
		                gc:drawThemeRect("button_normal", applyBounds)
		                gc.color = app.theme.color.button_normal_text
		                local applySize = gc:measureText(tr("apply"))
		                gc:fillText(tr("apply"),
		                        math.floor((actionButtonWidth-applySize.width)/2),
		                        math.floor((gc.height-applySize.height)/2))

		                local eraserBounds = Rectangle(eraserX, 0, eraserButtonWidth, gc.height)
		                gc:drawThemeRect("button_normal", eraserBounds)
		                gc.color = app.theme.color.button_normal_text
		                -- The toggle names the mode clicking it will switch to.
		                local eraserLabel = eraserOnly and tr("clone_stamp") or tr("eraser_only")
		                local eraserSize = gc:measureText(eraserLabel)
		                gc:fillText(eraserLabel,
		                        eraserX+math.floor((eraserButtonWidth-eraserSize.width)/2),
		                        math.floor((gc.height-eraserSize.height)/2))

		                -- Match the mode toggle: name the view clicking will show.
		                local beforeBounds = Rectangle(beforeX, 0, actionButtonWidth, gc.height)
		                gc:drawThemeRect("button_normal", beforeBounds)
		                gc.color = app.theme.color.button_normal_text
		                local beforeLabel = showBefore and tr("after") or tr("before")
		                local beforeSize = gc:measureText(beforeLabel)
		                gc:fillText(beforeLabel,
		                        beforeX+math.floor((actionButtonWidth-beforeSize.width)/2),
		                        math.floor((gc.height-beforeSize.height)/2))

		                -- Keep the live pixel status centered between the actions.
		                local coordText = hoveredPixelText()
		                local coordSize = gc:measureText(coordText)
		                local coordWidth = resetX-beforeRight
		                if coordWidth >= coordSize.width then
		                        gc.color = app.theme.color.button_normal_text
		                        gc:fillText(coordText,
		                                beforeRight+math.floor((coordWidth-coordSize.width)/2),
		                                math.floor((gc.height-coordSize.height)/2))
		                end

		                local resetBounds = Rectangle(resetX, 0, actionButtonWidth, gc.height)
		                gc:drawThemeRect("button_normal", resetBounds)
		                gc.color = app.theme.color.button_normal_text
		                local resetSize = gc:measureText(tr("reset"))
		                gc:fillText(tr("reset"),
		                        resetX+math.floor((actionButtonWidth-resetSize.width)/2),
		                        math.floor((gc.height-resetSize.height)/2))
		        end,
		        onmousedown=function(ev)
		                if ev.button ~= MouseButton.LEFT then return end

		                local eraserX = actionButtonWidth
		                local eraserRight = eraserX+eraserButtonWidth
		                local beforeX = eraserRight
		                local beforeRight = beforeX+actionButtonWidth
		                local resetX = math.max(beforeRight, footerWidth-actionButtonWidth)

		                applyPressed = insideFooterButton(ev, 0, actionButtonWidth)
		                eraserPressed = not applyPressed and
		                        insideFooterButton(ev, eraserX, eraserButtonWidth)
		                beforePressed = not applyPressed and not eraserPressed and
		                        insideFooterButton(ev, beforeX, actionButtonWidth)
		                resetPressed = not applyPressed and not eraserPressed and
		                        not beforePressed and
		                        insideFooterButton(ev, resetX, actionButtonWidth)
		        end,
		        onmouseup=function(ev)
		                if ev.button ~= MouseButton.LEFT then return end

		                local eraserX = actionButtonWidth
		                local eraserRight = eraserX+eraserButtonWidth
		                local beforeX = eraserRight
		                local beforeRight = beforeX+actionButtonWidth
		                local resetX = math.max(beforeRight, footerWidth-actionButtonWidth)

		                local applyActivate = applyPressed and
		                        insideFooterButton(ev, 0, actionButtonWidth)
		                local eraserActivate = eraserPressed and
		                        insideFooterButton(ev, eraserX, eraserButtonWidth)
		                local beforeActivate = beforePressed and
		                        insideFooterButton(ev, beforeX, actionButtonWidth)
		                local resetActivate = resetPressed and
		                        insideFooterButton(ev, resetX, actionButtonWidth)

		                applyPressed, eraserPressed, beforePressed, resetPressed =
		                        false, false, false, false

		                if beforeActivate then
		                        finishStroke()
		                        showBefore = not showBefore
		                        updateCanvasCursor()
		                        refreshPreview()
		                elseif showBefore then
		                        -- Comparison mode is view-only.
		                        return
		                elseif applyActivate then
		                        finishStroke()
		                        requestedAction = "apply"
		                        dlg:close()
		                elseif eraserActivate then
		                        finishStroke()
		                        if backgroundLayer then
		                                app.alert{
		                                        title=tr("clone_stamp"),
		                                        text=tr("eraser_needs_transparency")
		                                }
		                        else
		                                eraserOnly = not eraserOnly
		                                invalidatePreview()
		                                updateCanvasCursor()
		                                refreshPreview()
		                        end
		                elseif resetActivate then
		                        resetToStart()
		                end
		        end
		})

	-- Reopen the same dialog iteratively. Recursive onclose/show calls retain
	-- old canvases and can strand the session when the confirmation is closed.
	local function tryApply(x1, y1, x2, y2)
	        local ok, validationError = xpcall(function()
	                if x1 == nil then
	                        x1, y1, x2, y2 = getWorkDirtyBounds()
	                end

	                if x1 > x2 or y1 > y2 then return nil end

	                -- Expected rejection is a return value, never a transaction error.
	                local problem = validateSession()
	                if problem then return problem end

	                app.transaction(tr("clone_stamp"), function()
	                        applyToCel(x1, y1, x2, y2)
	                end)
	        end, errorTraceback)

	        if not ok then
	                reportFailure(tr("changes_not_applied"), validationError)
	                return false
	        end

	        if validationError then
	                app.alert{
	                        title=tr("clone_stamp"),
	                        text=validationError
	                }
	                return false
	        end

	        app.refresh()
	        return true
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
		-- Reset transient input, not the source, destination, view, or history.
		applyPressed, eraserPressed, beforePressed, resetPressed =
		        false, false, false, false
		updateCanvasCursor()
		dlg:show{ wait=true, bounds=bounds }
		stopMagnifier(false)
		if exiting then break end

		local shownBounds = dlg.bounds
		if usableDialogBounds(shownBounds) then
			bounds = copyDialogBounds(shownBounds)
		else
			bounds = initialDialogBounds()
		end
		if not callbackError then
			local ok, err = xpcall(finishStroke, errorTraceback)
			if not ok then callbackError = err end
		end
		isPanning, panButton, spaceHeld = false, nil, false

		local action = requestedAction
		requestedAction = nil

		if callbackError then
			-- Discard only a possibly incomplete operation, retaining the most
			-- recent completed undo snapshot. Never apply partially failed work.
			local err = callbackError
			cancelStroke()
			workImg = Image(undoStack[0])
			sessionDirtyPixels = {}
			for historyPos = 1, undoPos do
			        applyHistoryDelta(workImg, undoStack[historyPos], true)
			end
			snapshot = workImg
			callbackError = nil
			local choice = reportFailure(tr("changes_not_applied"), err,
				{ tr("continue_editing"), tr("discard") })
			if choice ~= 1 then break end
		elseif action == "apply" then
			if tryApply() then break end
		else
			local x1, y1, x2, y2 = getWorkDirtyBounds()
			if x1 > x2 or y1 > y2 then break end

			local choice = app.alert{
				title=tr("apply_changes"),
				text=strokeSummary(undoPos),
				buttons={ tr("apply"), tr("discard"), tr("continue_editing") }
			}

			if choice == 1 then
				if tryApply(x1, y1, x2, y2) then break end
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
	loadLocale(plugin)
	local prefs = plugin.preferences
	if prefs.radius == nil then prefs.radius = 14 end
	if prefs.softness == nil then prefs.softness = 0.67 end
	if prefs.spacing == nil then prefs.spacing = 0.25 end
	if prefs.opacity == nil then prefs.opacity = 1.0 end
	plugin:newCommand{ id="StampBrush_Clone", title=tr("clone_stamp"), group="edit_fill",
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
				reportFailure(tr("clone_stamp_failed"), err)
			end
		end,
		onenabled=function()
			return not sessionBusy and app.activeSprite ~= nil and app.activeCel ~= nil
		end }
end

function exit(plugin)
	exiting = true
	-- Control changes already save preferences; an unused session must not overwrite them.
	if dlg then pcall(function() dlg:close() end) end
	dlg = nil
	disposeState()
end
