local MODE_NORMAL = "normal"
local MODE_CONTEXT_TIMELINE = "context_timeline"
local MODE_EDITOR_ONLY = "editor_only"

local EXTENSION_VERSION = "0.1.10"
local RELEASE_REPO = "rauldeavila/focus-palette"
local CANVAS_ID = "focusPaletteCanvas"
local DEFAULT_BOUNDS = { x = 96, y = 96, width = 300, height = 260 }
local DEFAULT_SWATCH_SIZE = 32
local MIN_CELL_SIZE = 8
local MAX_CELL_SIZE = 96
local GAP = 2
local PAD = 2
local ZOOM_STEP = 4

local pluginRef = nil
local paletteDialog = nil
local focusActive = false
local timelineVisible = false
local timelineBeforeFocus = false
local knownMode = MODE_NORMAL
local modeBeforeFocus = MODE_NORMAL
local internalCommand = false
local closingPaletteProgrammatically = false
local listeners = {}
local lastLayout = nil
local toggleTimeline = nil
local repaintPalette = nil
local drag = nil
local pngImage = nil
local pngImagePath = nil
local pngLoadError = nil

local function clampInt(value, fallback, minValue)
  value = tonumber(value) or fallback
  value = math.floor(value)
  if minValue and value < minValue then
    return minValue
  end
  return value
end

local function ensurePreferences()
  local prefs = pluginRef.preferences

  if type(prefs.paletteBounds) ~= "table" then
    prefs.paletteBounds = {
      x = DEFAULT_BOUNDS.x,
      y = DEFAULT_BOUNDS.y,
      width = DEFAULT_BOUNDS.width,
      height = DEFAULT_BOUNDS.height
    }
  end

  if type(prefs.knownMode) ~= "string" then
    prefs.knownMode = MODE_NORMAL
  end

  if type(prefs.swatchSize) ~= "number" then
    prefs.swatchSize = DEFAULT_SWATCH_SIZE
  else
    prefs.swatchSize = clampInt(prefs.swatchSize, DEFAULT_SWATCH_SIZE, MIN_CELL_SIZE)
    if prefs.swatchSize > MAX_CELL_SIZE then
      prefs.swatchSize = MAX_CELL_SIZE
    end
  end

  if type(prefs.usePngPalette) ~= "boolean" then
    prefs.usePngPalette = false
  end

  if type(prefs.paletteImagePath) ~= "string" then
    prefs.paletteImagePath = ""
  end

  knownMode = prefs.knownMode
end

local function swatchSize()
  if not pluginRef then
    return DEFAULT_SWATCH_SIZE
  end

  return math.min(MAX_CELL_SIZE, clampInt(pluginRef.preferences.swatchSize, DEFAULT_SWATCH_SIZE, MIN_CELL_SIZE))
end

local function setSwatchSize(value)
  if not pluginRef then
    return
  end

  pluginRef.preferences.swatchSize = math.min(MAX_CELL_SIZE, clampInt(value, DEFAULT_SWATCH_SIZE, MIN_CELL_SIZE))

  if paletteDialog then
    paletteDialog:repaint()
  end
end

local function zoomSwatches(delta)
  setSwatchSize(swatchSize() + delta)
end

local function saveKnownMode()
  if pluginRef then
    pluginRef.preferences.knownMode = knownMode
  end
end

local function getPalette()
  if app.sprite and app.sprite.palettes and #app.sprite.palettes > 0 then
    return app.sprite.palettes[1]
  end

  return app.defaultPalette
end

local function isIndexedSprite()
  return app.sprite and app.sprite.colorMode == ColorMode.INDEXED
end

local function colorForIndex(index)
  if isIndexedSprite() then
    return Color { index = index }
  end

  local palette = getPalette()
  if not palette or index < 0 or index >= #palette then
    return Color { r = 0, g = 0, b = 0, a = 255 }
  end

  return palette:getColor(index)
end

local function usePngPalette()
  return pluginRef and pluginRef.preferences.usePngPalette == true
end

local function loadPngImage()
  if not pluginRef then
    return nil
  end

  local path = pluginRef.preferences.paletteImagePath
  if type(path) ~= "string" or path == "" then
    pngImage = nil
    pngImagePath = nil
    pngLoadError = "No PNG selected"
    return nil
  end

  if pngImage and pngImagePath == path then
    return pngImage
  end

  local ok, imageOrError = pcall(function()
    return Image { fromFile = path }
  end)

  if ok and imageOrError then
    pngImage = imageOrError
    pngImagePath = path
    pngLoadError = nil
    return pngImage
  end

  pngImage = nil
  pngImagePath = nil
  pngLoadError = tostring(imageOrError)
  return nil
end

local function pluginDataPath()
  return app.fs.joinPath(app.fs.userConfigPath, "focus-palette")
end

local function persistedPngPath()
  return app.fs.joinPath(pluginDataPath(), "palette.png")
end

local function copyFile(source, target)
  if source == target then
    return true
  end

  local input, inputError = io.open(source, "rb")
  if not input then
    return false, inputError
  end

  local data = input:read("*a")
  input:close()

  local output, outputError = io.open(target, "wb")
  if not output then
    return false, outputError
  end

  output:write(data)
  output:close()

  return true
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function readCommand(command)
  local handle = io.popen(command)
  if not handle then
    return nil
  end

  local output = handle:read("*a")
  handle:close()
  return output
end

local function parseVersion(version)
  local major, minor, patch = tostring(version):match("v?(%d+)%.(%d+)%.(%d+)")
  return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

local function isVersionNewer(remote, localVersion)
  local ra, rb, rc = parseVersion(remote)
  local la, lb, lc = parseVersion(localVersion)

  if ra ~= la then
    return ra > la
  elseif rb ~= lb then
    return rb > lb
  end

  return rc > lc
end

local function jsonStringField(text, field)
  local pattern = '"' .. field .. '"%s*:%s*"([^"]+)"'
  return text:match(pattern)
end

local function latestReleaseInfo(response)
  local tag = jsonStringField(response, "tag_name") or jsonStringField(response, "name")
  local downloadUrl = nil

  for block in response:gmatch("{.-}") do
    local name = jsonStringField(block, "name")
    local url = jsonStringField(block, "browser_download_url")

    if name and url and name:match("%.aseprite%-extension$") then
      downloadUrl = url:gsub("\\/", "/")
      break
    end
  end

  if not downloadUrl then
    downloadUrl = response:match('"browser_download_url"%s*:%s*"([^"]+%.aseprite%-extension)"')
    if downloadUrl then
      downloadUrl = downloadUrl:gsub("\\/", "/")
    end
  end

  return tag, downloadUrl
end

local function openFile(path)
  os.execute("open " .. shellQuote(path))
end

local function checkForUpdates()
  local apiUrl = "https://api.github.com/repos/" .. RELEASE_REPO .. "/releases/latest"
  local command = "curl -fsSL -H " ..
    shellQuote("Accept: application/vnd.github+json") .. " -H " ..
    shellQuote("User-Agent: focus-palette-aseprite") .. " " ..
    shellQuote(apiUrl)
  local response = readCommand(command)

  if not response or response == "" then
    app.alert {
      title = "Focus Palette",
      text = "Could not check GitHub releases."
    }
    return
  end

  local tag, downloadUrl = latestReleaseInfo(response)
  if not tag or tag == "" then
    app.alert {
      title = "Focus Palette",
      text = "Could not parse GitHub release data."
    }
    return
  end

  if not isVersionNewer(tag, EXTENSION_VERSION) then
    app.alert {
      title = "Focus Palette",
      text = "Focus Palette is up to date.\nInstalled: v" .. EXTENSION_VERSION
    }
    return
  end

  if not downloadUrl then
    app.alert {
      title = "Focus Palette",
      text = "A newer release exists (" .. tag .. "), but no .aseprite-extension asset was found."
    }
    return
  end

  local target = app.fs.joinPath(app.fs.tempPath, "focus-palette-" .. tag .. ".aseprite-extension")
  local downloadCommand = "curl -fsSL -o " .. shellQuote(target) .. " " .. shellQuote(downloadUrl)
  local result = os.execute(downloadCommand)

  if result ~= true and result ~= 0 then
    app.alert {
      title = "Focus Palette",
      text = "Could not download " .. tag .. "."
    }
    return
  end

  app.alert {
    title = "Focus Palette",
    text = "Downloaded " .. tag .. ". Aseprite will open the installer now."
  }
  openFile(target)
end

local function persistPngPalette(source)
  app.fs.makeAllDirectories(pluginDataPath())

  local target = persistedPngPath()
  local ok, err = copyFile(source, target)
  if not ok then
    app.alert {
      title = "Focus Palette",
      text = "Could not persist PNG palette: " .. tostring(err)
    }
    return nil
  end

  return target
end

local function colorFromPngPixel(pixel, colorMode)
  local pc = app.pixelColor

  if colorMode == ColorMode.GRAY then
    local value = pc.grayaV(pixel)
    return Color {
      r = value,
      g = value,
      b = value,
      a = pc.grayaA(pixel)
    }
  elseif colorMode == ColorMode.INDEXED then
    return Color { index = pixel }
  end

  return Color {
    r = pc.rgbaR(pixel),
    g = pc.rgbaG(pixel),
    b = pc.rgbaB(pixel),
    a = pc.rgbaA(pixel)
  }
end

local function cycleMode(mode)
  if mode == MODE_NORMAL then
    return MODE_CONTEXT_TIMELINE
  elseif mode == MODE_CONTEXT_TIMELINE then
    return MODE_EDITOR_ONLY
  end

  return MODE_NORMAL
end

local function runCommand(fn)
  internalCommand = true
  local ok, err = pcall(fn)
  internalCommand = false

  if not ok then
    app.alert {
      title = "Focus Palette",
      text = "Command failed: " .. tostring(err)
    }
  end

  return ok
end

local function readTimelinePreference()
  local ok, value = pcall(function()
    return app.preferences.general.visible_timeline
  end)

  return ok and value == true
end

local function advanceModeOnce()
  runCommand(function()
    app.command.AdvancedMode()
  end)
  knownMode = cycleMode(knownMode)
  saveKnownMode()
end

local function setMode(targetMode)
  local guard = 0
  while knownMode ~= targetMode and guard < 3 do
    advanceModeOnce()
    guard = guard + 1
  end
end

local function savePaletteBounds()
  if not pluginRef or not paletteDialog then
    return
  end

  local bounds = paletteDialog.bounds
  if not bounds then
    return
  end

  pluginRef.preferences.paletteBounds = {
    x = clampInt(bounds.x, DEFAULT_BOUNDS.x),
    y = clampInt(bounds.y, DEFAULT_BOUNDS.y),
    width = clampInt(bounds.width, DEFAULT_BOUNDS.width, 120),
    height = clampInt(bounds.height, DEFAULT_BOUNDS.height, 100)
  }
end

local function bestGrid(ncolors, width, height)
  local usableW = math.max(1, width - PAD * 2)
  local cell = swatchSize()
  local cols = math.floor((usableW + GAP) / (cell + GAP))

  if cols < 1 then
    cols = 1
  end

  if cols > ncolors then
    cols = ncolors
  end

  return {
    cols = cols,
    rows = math.ceil(ncolors / cols),
    cell = cell
  }
end

local function colorMatches(a, b, index)
  if not a or not b then
    return false
  end

  if isIndexedSprite() then
    return a.index == index
  end

  return a.rgbaPixel == b.rgbaPixel
end

local function paintPalette(ev)
  local gc = ev.context
  local width = gc.width
  local height = gc.height

  gc.antialias = false
  gc.color = Color { r = 32, g = 34, b = 38, a = 255 }
  gc:fillRect(Rectangle(0, 0, width, height))

  if usePngPalette() then
    local image = loadPngImage()
    if image then
      local scale = math.min(width / image.width, height / image.height)
      local drawWidth = math.max(1, math.floor(image.width * scale))
      local drawHeight = math.max(1, math.floor(image.height * scale))
      local drawX = math.floor((width - drawWidth) / 2)
      local drawY = math.floor((height - drawHeight) / 2)

      gc:drawImage(
        image,
        Rectangle(0, 0, image.width, image.height),
        Rectangle(drawX, drawY, drawWidth, drawHeight)
      )

      lastLayout = {
        type = "png",
        image = image,
        startX = drawX,
        startY = drawY,
        width = drawWidth,
        height = drawHeight,
        imageWidth = image.width,
        imageHeight = image.height
      }
    else
      gc.color = Color { r = 220, g = 220, b = 220, a = 255 }
      gc:fillText(pngLoadError or "PNG not loaded", PAD, PAD + 12)
      lastLayout = nil
    end

    return
  end

  local palette = getPalette()

  if not palette or #palette == 0 then
    gc.color = Color { r = 220, g = 220, b = 220, a = 255 }
    gc:fillText("No palette", PAD, PAD + 12)
    lastLayout = nil
    return
  end

  local ncolors = #palette
  local grid = bestGrid(ncolors, width, height)
  local gridW = grid.cols * grid.cell + (grid.cols - 1) * GAP
  local gridH = grid.rows * grid.cell + (grid.rows - 1) * GAP
  local startX = math.floor((width - gridW) / 2)
  local startY = math.floor((height - gridH) / 2)

  lastLayout = {
    ncolors = ncolors,
    cols = grid.cols,
    cell = grid.cell,
    startX = startX,
    startY = startY
  }

  local fg = app.fgColor
  local bg = app.bgColor

  for i = 0, ncolors - 1 do
    local col = i % grid.cols
    local row = math.floor(i / grid.cols)
    local x = startX + col * (grid.cell + GAP)
    local y = startY + row * (grid.cell + GAP)
    local rect = Rectangle(x, y, grid.cell, grid.cell)
    local color = colorForIndex(i)

    gc.color = color
    gc:fillRect(rect)

    gc.color = Color { r = 0, g = 0, b = 0, a = 255 }
    gc.strokeWidth = 1
    gc:strokeRect(rect)

    if colorMatches(fg, color, i) then
      gc.color = Color { r = 255, g = 255, b = 255, a = 255 }
      gc.strokeWidth = 2
      gc:strokeRect(Rectangle(x + 1, y + 1, math.max(1, grid.cell - 2), math.max(1, grid.cell - 2)))
    end

    if colorMatches(bg, color, i) then
      gc.color = Color { r = 255, g = 64, b = 96, a = 255 }
      gc.strokeWidth = 2
      gc:strokeRect(Rectangle(x + 3, y + 3, math.max(1, grid.cell - 6), math.max(1, grid.cell - 6)))
    end
  end
end

local function swatchAt(x, y)
  if not lastLayout then
    return nil
  end

  local relX = x - lastLayout.startX
  local relY = y - lastLayout.startY
  if relX < 0 or relY < 0 then
    return nil
  end

  local step = lastLayout.cell + GAP
  local col = math.floor(relX / step)
  local row = math.floor(relY / step)
  local cellX = relX - col * step
  local cellY = relY - row * step

  if cellX >= lastLayout.cell or cellY >= lastLayout.cell then
    return nil
  end

  local index = row * lastLayout.cols + col
  if index < 0 or index >= lastLayout.ncolors then
    return nil
  end

  return index
end

local function pickSwatch(x, y, button)
  if lastLayout and lastLayout.type == "png" then
    local relX = x - lastLayout.startX
    local relY = y - lastLayout.startY

    if relX < 0 or relY < 0 or relX >= lastLayout.width or relY >= lastLayout.height then
      return
    end

    local px = math.floor(relX * lastLayout.imageWidth / lastLayout.width)
    local py = math.floor(relY * lastLayout.imageHeight / lastLayout.height)
    px = math.max(0, math.min(lastLayout.imageWidth - 1, px))
    py = math.max(0, math.min(lastLayout.imageHeight - 1, py))

    local pixel = lastLayout.image:getPixel(px, py)
    local color = colorFromPngPixel(pixel, lastLayout.image.colorMode)

    if color.alpha == 0 then
      return
    end

    if button == MouseButton.RIGHT then
      app.bgColor = color
    else
      app.fgColor = color
    end

    if paletteDialog then
      paletteDialog:repaint()
    end

    return
  end

  local index = swatchAt(x, y)
  if index == nil then
    return
  end

  local color = colorForIndex(index)
  if button == MouseButton.RIGHT then
    app.bgColor = color
  else
    app.fgColor = color
  end

  if paletteDialog then
    paletteDialog:repaint()
  end
end

local function beginPalettePointer(ev)
  drag = {
    x = ev.x,
    y = ev.y,
    button = ev.button,
    active = false
  }
end

local function movePalettePointer(ev)
  if not drag or not paletteDialog then
    return
  end

  local dx = ev.x - drag.x
  local dy = ev.y - drag.y

  if not drag.active then
    if math.abs(dx) + math.abs(dy) < 4 then
      return
    end

    drag.active = true
  end

  local bounds = paletteDialog.bounds
  paletteDialog.bounds = Rectangle(
    bounds.x + dx,
    bounds.y + dy,
    bounds.width,
    bounds.height
  )
end

local function endPalettePointer(ev)
  if not drag then
    return
  end

  local wasDragging = drag.active
  local button = drag.button
  drag = nil

  if wasDragging then
    savePaletteBounds()
  else
    pickSwatch(ev.x, ev.y, button)
  end
end

local function wheelPalette(ev)
  if usePngPalette() then
    return
  end

  if ev.deltaY < 0 then
    zoomSwatches(ZOOM_STEP)
  elseif ev.deltaY > 0 then
    zoomSwatches(-ZOOM_STEP)
  end
end

local leaveFocusMode

local function resizeDialogToPng()
  if not paletteDialog or not usePngPalette() then
    return
  end

  local image = loadPngImage()
  if not image then
    return
  end

  local bounds = paletteDialog.bounds
  local width = clampInt(bounds.width, image.width, 32)
  local height = clampInt(bounds.height, image.height, 32)
  local saved = pluginRef.preferences.paletteBounds

  if saved then
    width = clampInt(saved.width, width, 32)
    height = clampInt(saved.height, height, 32)
  end

  paletteDialog.bounds = Rectangle(
    bounds.x,
    bounds.y,
    width,
    height
  )
  savePaletteBounds()
end

local function choosePngPalette()
  local picker = Dialog { title = "Focus Palette PNG" }

  picker:file {
    id = "filename",
    title = "Choose palette PNG",
    open = true,
    filetypes = { "png" },
    filename = pluginRef.preferences.paletteImagePath or ""
  }

  picker:button {
    id = "ok",
    text = "Use PNG",
    focus = true,
    onclick = function()
      local filename = picker.data.filename
      if type(filename) == "string" and filename ~= "" then
        local persisted = persistPngPalette(filename)
        if not persisted then
          picker:close()
          return
        end

        pluginRef.preferences.paletteImagePath = persisted
        pluginRef.preferences.usePngPalette = true
        pngImage = nil
        pngImagePath = nil
        pngLoadError = nil
        resizeDialogToPng()
        repaintPalette()
      end
      picker:close()
    end
  }

  picker:button {
    id = "cancel",
    text = "Cancel",
    onclick = function()
      picker:close()
    end
  }

  picker:show { wait = false }
end

local function togglePngPalette()
  pluginRef.preferences.usePngPalette = not pluginRef.preferences.usePngPalette

  if pluginRef.preferences.usePngPalette and
     (type(pluginRef.preferences.paletteImagePath) ~= "string" or
      pluginRef.preferences.paletteImagePath == "") then
    choosePngPalette()
    return
  end

  if pluginRef.preferences.usePngPalette then
    resizeDialogToPng()
  end

  repaintPalette()
end

local function showPaletteDialog()
  if paletteDialog then
    paletteDialog:repaint()
    return
  end

  local bounds = pluginRef.preferences.paletteBounds or DEFAULT_BOUNDS
  local initialBounds = Rectangle(
    clampInt(bounds.x, DEFAULT_BOUNDS.x),
    clampInt(bounds.y, DEFAULT_BOUNDS.y),
    clampInt(bounds.width, DEFAULT_BOUNDS.width, 120),
    clampInt(bounds.height, DEFAULT_BOUNDS.height, 100)
  )

  paletteDialog = Dialog {
    title = "Palette",
    notitlebar = true,
    resizeable = true,
    onclose = function()
      savePaletteBounds()
      paletteDialog = nil
      lastLayout = nil

      if focusActive and not closingPaletteProgrammatically and leaveFocusMode then
        leaveFocusMode()
      end
    end
  }

  paletteDialog:canvas {
    id = CANVAS_ID,
    width = math.max(120, initialBounds.width),
    height = math.max(100, initialBounds.height),
    hexpand = true,
    vexpand = true,
    onpaint = paintPalette,
    onmousedown = beginPalettePointer,
    onmousemove = movePalettePointer,
    onmouseup = endPalettePointer,
    onwheel = wheelPalette,
    onkeydown = function(ev)
      if ev.code == "Tab" then
        ev:stopPropagation()
        toggleTimeline()
      elseif ev.key == "+" or ev.key == "=" or ev.code == "NumpadAdd" then
        ev:stopPropagation()
        if not usePngPalette() then
          zoomSwatches(ZOOM_STEP)
        end
      elseif ev.key == "-" or ev.code == "NumpadSubtract" then
        ev:stopPropagation()
        if not usePngPalette() then
          zoomSwatches(-ZOOM_STEP)
        end
      end
    end
  }

  paletteDialog:show {
    wait = false,
    bounds = initialBounds
  }
  savePaletteBounds()
end

repaintPalette = function()
  if paletteDialog then
    paletteDialog:repaint()
  end
end

local function closePaletteDialog()
  if not paletteDialog then
    return
  end

  savePaletteBounds()
  closingPaletteProgrammatically = true
  paletteDialog:close()
  closingPaletteProgrammatically = false
  paletteDialog = nil
  lastLayout = nil
end

local function openTimeline()
  setMode(MODE_CONTEXT_TIMELINE)
  runCommand(function()
    app.command.Timeline { open = true }
  end)
  timelineVisible = true
end

local function closeTimeline()
  runCommand(function()
    app.command.Timeline { close = true }
  end)
  setMode(MODE_EDITOR_ONLY)
  timelineVisible = false
end

toggleTimeline = function()
  if timelineVisible then
    closeTimeline()
  else
    openTimeline()
  end
end

local function enterFocusMode()
  if focusActive then
    return
  end

  modeBeforeFocus = knownMode
  timelineBeforeFocus = readTimelinePreference()
  focusActive = true
  timelineVisible = false

  runCommand(function()
    app.command.Timeline { close = true }
  end)
  setMode(MODE_EDITOR_ONLY)
  showPaletteDialog()
end

leaveFocusMode = function()
  if not focusActive then
    closePaletteDialog()
    return
  end

  focusActive = false
  timelineVisible = false
  closePaletteDialog()

  if modeBeforeFocus == MODE_CONTEXT_TIMELINE then
    setMode(MODE_CONTEXT_TIMELINE)
  elseif modeBeforeFocus == MODE_EDITOR_ONLY then
    setMode(MODE_EDITOR_ONLY)
  else
    setMode(MODE_NORMAL)
  end

  runCommand(function()
    if timelineBeforeFocus then
      app.command.Timeline { open = true }
    else
      app.command.Timeline { close = true }
    end
  end)
end

local function toggleFocusMode()
  if focusActive then
    leaveFocusMode()
  else
    enterFocusMode()
  end
end

local function handleBeforeCommand(ev)
  if internalCommand then
    return
  end

  if focusActive and ev.name == "Timeline" then
    ev.stopPropagation()
    toggleTimeline()
  end
end

local function handleAfterCommand(ev)
  if ev.name == "AdvancedMode" and not internalCommand then
    knownMode = cycleMode(knownMode)
    saveKnownMode()
  end

  if focusActive and (ev.name == "LoadPalette" or ev.name == "SavePalette" or ev.name == "PaletteSize") then
    repaintPalette()
  end
end

function init(plugin)
  pluginRef = plugin
  ensurePreferences()

  plugin:newCommand {
    id = "FocusPaletteMode",
    title = "Focus Palette Mode",
    group = "view_controls",
    onclick = toggleFocusMode,
    onenabled = function()
      return app.isUIAvailable
    end,
    onchecked = function()
      return focusActive
    end
  }

  plugin:newCommand {
    id = "FocusPaletteChoosePng",
    title = "Focus Palette: Choose PNG...",
    group = "view_controls",
    onclick = choosePngPalette,
    onenabled = function()
      return app.isUIAvailable
    end
  }

  plugin:newCommand {
    id = "FocusPaletteUsePng",
    title = "Focus Palette: Use PNG Palette",
    group = "view_controls",
    onclick = togglePngPalette,
    onenabled = function()
      return app.isUIAvailable
    end,
    onchecked = function()
      return pluginRef.preferences.usePngPalette == true
    end
  }

  plugin:newCommand {
    id = "FocusPaletteCheckUpdates",
    title = "Focus Palette: Check for Updates...",
    group = "view_controls",
    onclick = checkForUpdates,
    onenabled = function()
      return app.isUIAvailable
    end
  }

  listeners.beforeCommand = app.events:on("beforecommand", handleBeforeCommand)
  listeners.afterCommand = app.events:on("aftercommand", handleAfterCommand)
  listeners.siteChange = app.events:on("sitechange", repaintPalette)
  listeners.fgColorChange = app.events:on("fgcolorchange", repaintPalette)
  listeners.bgColorChange = app.events:on("bgcolorchange", repaintPalette)
end

function exit(plugin)
  if app and app.events then
    for _, listener in pairs(listeners) do
      pcall(function()
        app.events:off(listener)
      end)
    end
  end

  if focusActive then
    leaveFocusMode()
  else
    closePaletteDialog()
  end

  saveKnownMode()
end
