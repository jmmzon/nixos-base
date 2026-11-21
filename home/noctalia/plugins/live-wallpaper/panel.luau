--!nonstrict
-- @include erebor-modes
-- Live wallpaper picker: the Sequoia scene and "shader:" wallpapers.
--
-- Shaders come from the same directories Noctalia searches: the
-- [wallpaper.shader] directories, then noctalia/shaders under $XDG_DATA_HOME and
-- each $XDG_DATA_DIRS entry. A subdirectory with a shader_index.json (KDE Shader
-- Wallpaper's library layout) lists its shaders with names, categories and
-- flags; loose .frag files show under "Mine". A tile sets "shader:<dir>/<path>"
-- (or "sequoia:") on the chosen output, or on all of them.
--
-- Previews: noctalia-shader-thumbnail renders missing ones in the background
-- into ~/.cache/noctalia/shader-thumbnails: the visible page first, then the
-- next page, then (from the first open on) the rest of the library.
--
-- Stop puts back the image wallpaper an output had before a live one was set
-- here (remembered in the plugin data dir). Pause freezes shader wallpapers
-- ([wallpaper.shader] paused) or, for Sequoia, switches its desktop motion.
-- While power-saver (erebor-modes) holds the animation, a card from the shared
-- erebor-modes component replaces the picker, with buttons to leave the mode.

local PANEL_WIDTH = 980
local PANEL_PADDING = 28
local COLUMNS = 4
local COLUMN_GAP = 12
local PAGE_SIZE = 16
local TILE_RADIUS = 12
local THUMB_TOOL = "noctalia-shader-thumbnail"
local THUMB_BATCH = 12
local THUMB_TIMEOUT_MS = 60000
local PAUSE_RULES = { "off", "fullscreen", "maximized", "covered" }

-- erebor-modes items that stop the animation (modules/erebor-modes.nix).
local MODE_ITEMS = { "wallpaper-shader", "wallpaper-sequoia", "wallpaper-engine" }

local closeButton = true
local items = {} -- { kind = "sequoia" | "shader", path, spec, name, category, author, flags, preview }
local filtered = {}
local page = 1
local query = ""
local categories = {}
local categoryIndex = 0 -- 0 = all
local outputsList = {}
local selectedConnectorName = "" -- empty = all outputs
local showSettings = false
local previous = {} -- connector -> image wallpaper before a live one
local thumbJobRunning = false
local failedThumbs = {} -- spec -> true
local retryAlone = {} -- spec -> true: cut off by a timed-out batch, rendered alone next
local backgroundThumbs = false -- set on the first open: render the whole library
local thumbnailerAvailable = false
local sliderValues = {} -- live slider positions while dragging
local loadedAtMs = nil -- when the shader list was last read (it is kept between opens)
local RELOAD_AFTER_MS = 60000
local speedText = nil -- the speed box while it is being edited

local render

local function tr(key)
  return noctalia.tr(key)
end

-- ── Paths ──────────────────────────────────────────────────────────────────

local function home()
  return noctalia.getenv("HOME") or ""
end

local function xdg(var, fallback)
  local value = noctalia.getenv(var)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return home() .. "/" .. fallback
end

local function thumbDir()
  return xdg("XDG_CACHE_HOME", ".cache") .. "/noctalia/shader-thumbnails"
end

local function thumbFile(spec)
  local name = spec:gsub("[^%w%._%-]", "_")
  return thumbDir() .. "/" .. name .. ".png"
end

local function previousFile()
  return noctalia.pluginDataDir() .. "/previous.json"
end

local function searchDirs()
  local dirs, seen = {}, {}
  local function add(dir)
    if type(dir) == "string" and dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end
  local configured = noctalia.getSetting("wallpaper.shader.directories")
  if type(configured) == "table" then
    for _, dir in ipairs(configured) do
      add(noctalia.expandPath(dir))
    end
  end
  add(xdg("XDG_DATA_HOME", ".local/share") .. "/noctalia/shaders")
  local dataDirs = noctalia.getenv("XDG_DATA_DIRS")
  if type(dataDirs) ~= "string" or dataDirs == "" then
    dataDirs = "/usr/local/share:/usr/share"
  end
  for entry in dataDirs:gmatch("[^:]+") do
    add(entry .. "/noctalia/shaders")
  end
  return dirs, configured
end

-- ── Live wallpaper state ───────────────────────────────────────────────────

local function hasPatch()
  return noctalia.getSetting("wallpaper.shader.render_scale") ~= nil
end

local function sequoiaAvailable()
  return noctalia.getSetting("wallpaper.sequoia.desktop_motion") ~= nil
end

local function isLive(path)
  return type(path) == "string" and (path:sub(1, 7) == "shader:" or path:sub(1, 8) == "sequoia:")
end

local function targetConnectors()
  if selectedConnectorName ~= "" then
    return { selectedConnectorName }
  end
  local names = {}
  for _, output in ipairs(outputsList) do
    table.insert(names, output.name)
  end
  return names
end

-- "shader", "sequoia" or nil: what the selection shows (shader wins over Sequoia).
local function selectionLiveKind()
  local kind = nil
  for _, connector in ipairs(targetConnectors()) do
    local path = noctalia.wallpaperPath(connector)
    if type(path) == "string" then
      if path:sub(1, 7) == "shader:" then
        return "shader"
      elseif path:sub(1, 8) == "sequoia:" then
        kind = "sequoia"
      end
    end
  end
  return kind
end

local function isCurrent(item)
  for _, connector in ipairs(targetConnectors()) do
    if noctalia.wallpaperPath(connector) == item.path then
      return true
    end
  end
  return false
end

local function canStop()
  for _, connector in ipairs(targetConnectors()) do
    if previous[connector] ~= nil and isLive(noctalia.wallpaperPath(connector)) then
      return true
    end
  end
  return false
end

local function loadPrevious()
  local content = noctalia.readFile(previousFile())
  local decoded = type(content) == "string" and noctalia.json.decode(content) or nil
  previous = type(decoded) == "table" and decoded or {}
end

local function savePrevious()
  noctalia.mkdirAll(noctalia.pluginDataDir())
  noctalia.writeFile(previousFile(), noctalia.json.encode(previous))
end

-- ── Settings writes (noctalia msg config-set, as the toggles plugin does) ──

local function configSet(key, tomlValue)
  noctalia.runAsync({ "noctalia", "msg", "config-set", key, tomlValue }, function(result)
    if type(result) == "table" and (result.exitCode ~= 0 or (type(result.stdout) == "string" and result.stdout:find("^error"))) then
      noctalia.notifyError(tr("title"), tr("config_failed") .. ": " .. tostring(result.stdout or result.stderr))
    end
    render()
  end)
end

local function quoted(text)
  return '"' .. text .. '"'
end

-- ── Loading ────────────────────────────────────────────────────────────────

local function newestSequoiaStill()
  local dir = xdg("XDG_STATE_HOME", ".local/state") .. "/noctalia"
  local entries = noctalia.listDir(dir)
  local best = nil
  if type(entries) == "table" then
    for _, name in ipairs(entries) do
      if name:match("^sequoia%-still%-%d+%.png$") and (best == nil or name > best) then
        best = name
      end
    end
  end
  return best and (dir .. "/" .. best) or nil
end

local function addLibrary(seen, dir, library)
  local root = dir .. "/" .. library
  -- picker_index.json: a slim copy some packages ship (cheaper to decode than the full index).
  local content = noctalia.readFile(root .. "/picker_index.json")
  if type(content) ~= "string" then
    content = noctalia.readFile(root .. "/shader_index.json")
  end
  local index = type(content) == "string" and noctalia.json.decode(content) or nil
  if type(index) ~= "table" or type(index.shaders) ~= "table" then
    return
  end
  for _, entry in ipairs(index.shaders) do
    local rel = type(entry.shaderPath) == "string" and entry.shaderPath or nil
    -- Trust the index: a file check per shader costs too much of onOpen's CPU budget.
    if rel ~= nil and rel:match("%.frag$") then
      local spec = library .. "/" .. rel:gsub("%.frag$", "")
      if not seen[spec] then
        seen[spec] = true
        table.insert(items, {
          kind = "shader",
          path = "shader:" .. spec,
          spec = spec,
          name = type(entry.name) == "string" and entry.name ~= "" and entry.name or rel,
          category = type(entry.category) == "string" and entry.category ~= "" and entry.category or "Other",
          author = type(entry.author) == "string" and entry.author or "",
          flags = {
            buffers = entry.hasBuffers == true,
            audio = entry.needsAudio == true,
            textures = entry.needsTextures == true,
            windows = rel:find("WindowReactive", 1, true) ~= nil,
          },
        })
      end
    end
  end
end

local function addLoose(seen, dir, name)
  if not name:match("%.frag$") or name:match("_buffer[A-D]%.frag$") or name:match("_common%.frag$") then
    return
  end
  local spec = name:gsub("%.frag$", "")
  if seen[spec] then
    return
  end
  seen[spec] = true
  table.insert(items, {
    kind = "shader",
    path = "shader:" .. spec,
    spec = spec,
    name = spec,
    category = tr("category_mine"),
    author = "",
    flags = { buffers = noctalia.fileExists(dir .. "/" .. spec .. "_bufferA.frag") },
  })
end

local function applyFilter()
  filtered = {}
  local needle = query:lower()
  local wanted = categoryIndex > 0 and categories[categoryIndex] or nil
  for _, item in ipairs(items) do
    local categoryOk = wanted == nil or item.category == wanted
    local textOk = needle == ""
      or item.name:lower():find(needle, 1, true) ~= nil
      or item.category:lower():find(needle, 1, true) ~= nil
      or (item.author ~= "" and item.author:lower():find(needle, 1, true) ~= nil)
    if categoryOk and textOk then
      table.insert(filtered, item)
    end
  end
  page = math.min(page, math.max(1, math.ceil(#filtered / PAGE_SIZE)))
end

local function loadItems()
  items = {}
  local seen = {}
  local shaders = {}
  if sequoiaAvailable() then
    table.insert(items, {
      kind = "sequoia",
      path = "sequoia:",
      name = tr("sequoia_name"),
      category = tr("category_sequoia"),
      author = "",
      flags = {},
      preview = newestSequoiaStill(),
    })
  end
  local dirs = searchDirs()
  for _, dir in ipairs(dirs) do
    local entries = noctalia.listDir(dir)
    if type(entries) == "table" then
      table.sort(entries)
      for _, name in ipairs(entries) do
        if name:match("%.frag$") then
          addLoose(seen, dir, name)
        elseif noctalia.fileExists(dir .. "/" .. name .. "/shader_index.json") then
          addLibrary(seen, dir, name)
        end
      end
    end
  end
  -- Sequoia first, then by name.
  local first = items[1] ~= nil and items[1].kind == "sequoia" and table.remove(items, 1) or nil
  table.sort(items, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  if first ~= nil then
    table.insert(items, 1, first)
  end
  local set = {}
  categories = {}
  for _, item in ipairs(items) do
    if not set[item.category] then
      set[item.category] = true
      table.insert(categories, item.category)
    end
  end
  table.sort(categories)
  if categoryIndex > #categories then
    categoryIndex = 0
  end
  applyFilter()
end

local function refreshOutputs()
  outputsList = noctalia.outputs() or {}
  if selectedConnectorName == "" then
    return
  end
  for _, output in ipairs(outputsList) do
    if output.name == selectedConnectorName then
      return
    end
  end
  selectedConnectorName = ""
end

-- ── Previews ───────────────────────────────────────────────────────────────

local function pageRange()
  local first = (page - 1) * PAGE_SIZE + 1
  return first, math.min(first + PAGE_SIZE - 1, #filtered)
end

-- Which thumbnails exist: one directory listing per job instead of a file check
-- per tile or per library entry (those cost too much of a callback's CPU budget).
local thumbNames = nil -- file name -> true; nil = list again

local function haveThumb(spec)
  if thumbNames == nil then
    thumbNames = {}
    for _, name in ipairs(noctalia.listDir(thumbDir()) or {}) do
      thumbNames[name] = true
    end
  end
  return thumbNames[(spec:gsub("[^%w%._%-]", "_")) .. ".png"] == true
end

local function wantsThumb(item)
  return item.kind == "shader" and not failedThumbs[item.spec] and not haveThumb(item.spec)
end

-- What to render next, most wanted first: the visible page, the next page, then
-- (once the panel has been opened) the whole library in the background. A spec
-- cut off by a timed-out job is retried alone, so one slow shader cannot fail a
-- whole batch; a failure alone marks it failed for good.
local function nextThumbBatch()
  local specs, taken = {}, {}
  local function take(item)
    if #specs < THUMB_BATCH and not taken[item.spec] and wantsThumb(item) then
      taken[item.spec] = true
      table.insert(specs, item.spec)
    end
  end
  local solo = next(retryAlone)
  if solo ~= nil then
    return { solo }, true
  end
  local first, last = pageRange()
  for i = first, math.min(last + PAGE_SIZE, #filtered) do
    take(filtered[i])
  end
  if #specs == 0 and backgroundThumbs then
    for _, item in ipairs(items) do
      take(item)
      if #specs == THUMB_BATCH then
        break
      end
    end
  end
  return specs, false
end

local function requestThumbnails()
  if thumbJobRunning or not thumbnailerAvailable then
    return
  end
  local specs, alone = nextThumbBatch()
  if #specs == 0 then
    return
  end
  local argv = { THUMB_TOOL, "--out", thumbDir() }
  local _, configured = searchDirs()
  if type(configured) == "table" then
    for _, dir in ipairs(configured) do
      table.insert(argv, "--dir")
      table.insert(argv, noctalia.expandPath(dir))
    end
  end
  for _, spec in ipairs(specs) do
    table.insert(argv, spec)
  end
  thumbJobRunning = true
  noctalia.runAsync(argv, function(result)
    thumbJobRunning = false
    thumbNames = nil
    local settled = {}
    if type(result) == "table" and type(result.stdout) == "string" then
      for line in result.stdout:gmatch("[^\n]+") do
        local status, spec = line:match("^(%a+) (%S+)")
        if status == "ok" then
          settled[spec] = true
        elseif status == "fail" then
          settled[spec] = true
          failedThumbs[spec] = true
        end
      end
    end
    -- Neither rendered nor failed: the job timed out before reaching it.
    for _, spec in ipairs(specs) do
      retryAlone[spec] = nil
      if not settled[spec] and not haveThumb(spec) then
        if alone then
          failedThumbs[spec] = true
        else
          retryAlone[spec] = true
        end
      end
    end
    render() -- also starts the next job
  end, THUMB_TIMEOUT_MS)
end

-- ── Rendering ──────────────────────────────────────────────────────────────

local function totalPages()
  return math.max(1, math.ceil(#filtered / PAGE_SIZE))
end

local function outputOptions()
  local options = { tr("all_outputs") }
  for _, output in ipairs(outputsList) do
    table.insert(options, output.name)
  end
  return options
end

local function selectedOutputIndex()
  for i, output in ipairs(outputsList) do
    if output.name == selectedConnectorName then
      return i
    end
  end
  return 0
end

local function categoryOptions()
  local options = { tr("all_categories") }
  for _, category in ipairs(categories) do
    table.insert(options, category)
  end
  return options
end

local function tileSize()
  local width = math.floor(((PANEL_WIDTH - PANEL_PADDING) - COLUMN_GAP * (COLUMNS - 1)) / COLUMNS)
  return width, math.floor(width * 9 / 16)
end

local function badges(item)
  local list = {}
  local function add(glyph, key)
    table.insert(list, ui.glyph({ name = glyph, size = 12, color = "on_surface_variant", tooltip = tr(key) }))
  end
  if item.flags.buffers then
    add("atom", "badge_buffers")
  end
  if item.flags.windows then
    add("app-window", "badge_windows")
  end
  if item.flags.textures then
    add("photo", "badge_textures")
  end
  if item.flags.audio then
    add("volume-off", "badge_audio")
  end
  return list
end

local function itemTile(item)
  local frameWidth, frameHeight = tileSize()
  local selected = isCurrent(item)
  local onClick = function()
    for _, connector in ipairs(targetConnectors()) do
      local current = noctalia.wallpaperPath(connector)
      if type(current) == "string" and current ~= "" and not isLive(current) then
        previous[connector] = current
      end
    end
    savePrevious()
    if selectedConnectorName == "" then
      noctalia.setWallpaper(item.path)
    else
      noctalia.setWallpaper(selectedConnectorName, item.path)
    end
    render()
  end
  local tooltip = item.name .. " · " .. item.category .. (item.author ~= "" and (" · " .. item.author) or "")
  local preview = item.preview
  if item.kind == "shader" and haveThumb(item.spec) then
    preview = thumbFile(item.spec)
  end

  local frame
  local frameProps = {
    width = frameWidth,
    height = frameHeight,
    radius = TILE_RADIUS,
    border = selected and "primary" or "outline_variant",
    borderWidth = selected and 3 or 1,
    tooltip = tooltip,
    onClick = onClick,
  }
  if preview ~= nil then
    frameProps.path = preview
    frameProps.fit = "cover"
    frame = ui.image(frameProps)
  else
    -- A column, not a box: boxes take no children or alignment.
    frameProps.fill = "surface_container"
    frameProps.align = "center"
    frameProps.justify = "center"
    local glyph = item.kind == "sequoia" and "trees" or (failedThumbs[item.spec] and "alert-triangle" or "sparkles")
    frame = ui.column(frameProps, { ui.glyph({ name = glyph, size = 28, color = "on_surface_variant" }) })
  end

  local caption = {
    ui.label({
      text = item.name,
      fontSize = 11,
      color = selected and "primary" or "on_surface_variant",
      maxLines = 1,
      maxWidth = frameWidth - 70,
    }),
    ui.spacer({ flexGrow = 1 }),
  }
  for _, badge in ipairs(badges(item)) do
    table.insert(caption, badge)
  end
  return ui.column({ gap = 4, key = item.path, flexGrow = 1, align = "stretch" }, {
    frame,
    ui.row({ gap = 4, align = "center" }, caption),
  })
end

local function itemGrid()
  if not hasPatch() then
    return ui.label({ text = tr("no_patch"), color = "error" })
  end
  if #filtered == 0 then
    return ui.label({ text = #items == 0 and tr("empty") or tr("no_match"), color = "on_surface_variant" })
  end
  local first, last = pageRange()
  local rows, row = {}, {}
  for i = first, last do
    table.insert(row, itemTile(filtered[i]))
    if #row == COLUMNS or i == last then
      while #row < COLUMNS do
        table.insert(row, ui.spacer({ flexGrow = 1 }))
      end
      table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
      row = {}
    end
  end
  return ui.column({ gap = 12, align = "stretch" }, rows)
end

local function pauseRuleIndex()
  local rule = noctalia.getSetting("wallpaper.shader.pause_when_covered")
  for i, value in ipairs(PAUSE_RULES) do
    if value == rule then
      return i - 1
    end
  end
  return 0
end

-- Fixed-width label column, so the controls line up (labels size to their text).
local function settingLabel(text)
  return ui.column({ width = 170 }, { ui.label({ text = text, fontSize = 12, color = "on_surface" }) })
end

local function settingSlider(key, labelKey, min, max, step, format)
  local value = sliderValues[key] or noctalia.getSetting(key) or min
  return ui.row({ gap = 12, align = "center" }, {
    settingLabel(tr(labelKey)),
    ui.slider({
      key = key,
      min = min,
      max = max,
      step = step,
      value = value,
      flexGrow = 1,
      -- Control callbacks pass values as strings; onDragEnd passes none.
      onChange = function(v)
        sliderValues[key] = tonumber(v) or sliderValues[key]
        render()
      end,
      onDragEnd = function()
        local final = sliderValues[key]
        sliderValues[key] = nil
        if final ~= nil then
          configSet(key, tostring(final))
        end
      end,
    }),
    ui.label({ text = string.format(format, value), fontSize = 12, color = "on_surface_variant", width = 56 }),
  })
end

-- Speed, precisely: a slider in 0.01 steps, a box for an exact value (clamped to
-- the setting's range; Enter applies it, or the service does once typing pauses)
-- and a 1x reset. It sets Sequoia's desktop speed
-- when Sequoia is the selection's wallpaper, the shader speed otherwise.
local function speedTarget()
  if selectionLiveKind() == "sequoia" then
    return { key = "wallpaper.sequoia.desktop_speed", label = "setting_speed_sequoia", min = 0.05, max = 2.0 }
  end
  return { key = "wallpaper.shader.speed", label = "setting_speed", min = 0.0, max = 4.0 }
end

local function formatSpeed(value)
  local text = string.format("%.3f", value):gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function applySpeed(target, value)
  value = math.max(target.min, math.min(target.max, value))
  configSet(target.key, string.format("%.4f", value))
end

local function speedRow()
  local target = speedTarget()
  local value = tonumber(sliderValues[target.key]) or tonumber(noctalia.getSetting(target.key)) or 1.0
  return ui.row({ gap = 12, align = "center" }, {
    settingLabel(tr(target.label)),
    ui.slider({
      key = "speed:" .. target.key,
      min = target.min,
      max = target.max,
      step = 0.01,
      value = value,
      flexGrow = 1,
      onChange = function(v)
        sliderValues[target.key] = tonumber(v) or sliderValues[target.key]
        speedText = nil
        render()
      end,
      onDragEnd = function()
        local final = sliderValues[target.key]
        sliderValues[target.key] = nil
        if final ~= nil then
          applySpeed(target, final)
        end
      end,
    }),
    ui.input({
      key = "speed-box:" .. target.key,
      value = speedText or formatSpeed(value),
      width = 84,
      submitOnEnter = true,
      onChange = function(text)
        speedText = tostring(text or "")
        -- Applied by the service once typing pauses (panels have no timers), so a
        -- value works without Enter.
        noctalia.state.set("speedPending", {
          key = target.key,
          min = target.min,
          max = target.max,
          text = speedText,
          at = noctalia.nowMs(),
        })
      end,
      onSubmit = function(text)
        noctalia.state.set("speedPending", nil)
        local typed = tonumber((tostring(text or ""):gsub(",", "."):gsub("[x×%s]", "")))
        speedText = nil
        if typed ~= nil then
          applySpeed(target, typed)
        else
          render()
        end
      end,
    }),
    ui.button({
      text = "1×",
      variant = "ghost",
      tooltip = tr("speed_reset"),
      enabled = math.abs(value - 1.0) > 1e-6,
      onClick = function()
        speedText = nil
        applySpeed(target, 1.0)
      end,
    }),
  })
end

local function settingsStrip()
  local animated = noctalia.getSetting("wallpaper.shader.desktop_motion") ~= "still"
  local ruleOptions = {}
  for _, value in ipairs(PAUSE_RULES) do
    table.insert(ruleOptions, tr("pause_" .. value))
  end
  return ui.column({ gap = 10, align = "stretch" }, {
    ui.row({ gap = 12, align = "center" }, {
      settingLabel(tr("setting_pause_rule")),
      ui.select({
        key = "pause_rule",
        options = ruleOptions,
        selectedIndex = pauseRuleIndex(),
        flexGrow = 1,
        onChange = function(index, _label)
          local value = PAUSE_RULES[(tonumber(index) or 0) + 1]
          if value ~= nil then
            configSet("wallpaper.shader.pause_when_covered", quoted(value))
          end
        end,
      }),
      ui.label({ text = tr("setting_animate"), fontSize = 12, color = "on_surface" }),
      ui.toggle({
        key = "animate",
        checked = animated,
        onChange = function(checked)
          local on = checked == true or checked == "true" -- toggles report "true" / "false"
          configSet("wallpaper.shader.desktop_motion", quoted(on and "animated" or "still"))
        end,
      }),
    }),
    settingSlider("wallpaper.shader.desktop_fps", "setting_fps", 10, 120, 5, "%d fps"),
    settingSlider("wallpaper.shader.render_scale", "setting_scale", 0.25, 1.0, 0.05, "%.2f×"),
    speedRow(),
  })
end

render = function()
  -- While a mode (power-saver) holds the animation, the picker is blocked.
  local held = EreborModes.holding(MODE_ITEMS)
  if held ~= nil then
    panel.render(EreborModes.card(held, tr("held_what"), closeButton))
    return
  end
  refreshOutputs()
  local liveKind = selectionLiveKind()
  local shaderPaused = noctalia.getSetting("wallpaper.shader.paused") == true
  local sequoiaStill = noctalia.getSetting("wallpaper.sequoia.desktop_motion") == "still"
  local paused = (liveKind == "shader" and shaderPaused) or (liveKind == "sequoia" and sequoiaStill)

  local header = {
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if thumbJobRunning then
    table.insert(header, ui.label({ text = tr("rendering_previews"), fontSize = 12, color = "on_surface_variant" }))
  end
  table.insert(header, ui.label({ text = `{#filtered} / {#items}`, fontSize = 12, color = "on_surface_variant" }))
  table.insert(header, ui.button({
    glyph = "adjustments",
    variant = showSettings and "default" or "ghost",
    selected = showSettings,
    tooltip = tr("settings_button"),
    onClick = "onToggleSettings",
  }))
  if closeButton then
    table.insert(header, ui.button({ glyph = "close", onClick = "onClose" }))
  end

  local body = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, header),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "search", value = query, placeholder = tr("search"), onChange = "onSearch", flexGrow = 1 }),
      ui.select({
        key = "category",
        options = categoryOptions(),
        selectedIndex = categoryIndex,
        onChange = "onCategoryChange",
        width = 220,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("output"), fontSize = 12, color = "on_surface_variant" }),
      ui.select({
        key = "output",
        options = outputOptions(),
        selectedIndex = selectedOutputIndex(),
        onChange = "onOutputChange",
        flexGrow = 1,
      }),
      ui.button({
        text = liveKind == "sequoia" and (sequoiaStill and tr("sequoia_animated") or tr("sequoia_still"))
          or (paused and tr("resume") or tr("pause")),
        glyph = paused and "player-play" or "player-pause",
        variant = "outline",
        tooltip = liveKind == "sequoia" and tr("pause_tooltip_sequoia") or tr("pause_tooltip_shader"),
        onClick = "onTogglePause",
        enabled = liveKind ~= nil,
      }),
      ui.button({
        text = tr("stop"),
        glyph = "player-stop",
        variant = "outline",
        tooltip = tr("stop_tooltip"),
        onClick = "onStop",
        enabled = canStop(),
      }),
    }),
  }
  if showSettings and hasPatch() then
    table.insert(body, settingsStrip())
    table.insert(body, ui.separator({}))
  end
  table.insert(body, ui.scroll({ flexGrow = 1, gap = 12 }, { itemGrid() }))
  table.insert(body, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "onPrevPage", enabled = page > 1 }),
    ui.label({
      text = `{page} / {totalPages()}` .. (thumbnailerAvailable and "" or ("  ·  " .. tr("no_thumbnailer"))),
      color = "on_surface_variant",
    }),
    ui.button({ glyph = "chevron-right", variant = "ghost", onClick = "onNextPage", enabled = page < totalPages() }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, body))
  requestThumbnails()
end

-- ── Callbacks ──────────────────────────────────────────────────────────────

function onOpen(_context)
  closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  thumbnailerAvailable = noctalia.commandExists(THUMB_TOOL)
  backgroundThumbs = true
  thumbNames = nil -- the cache may have been cleared or filled meanwhile
  loadPrevious()
  refreshOutputs()
  -- Reading every library is the costly part of opening: reuse the list for a minute.
  local now = noctalia.nowMs()
  if loadedAtMs == nil or now - loadedAtMs > RELOAD_AFTER_MS then
    loadItems()
    loadedAtMs = now
  else
    applyFilter()
  end
  render()
end

function onConfigChanged()
  render()
end

function onSearch(text)
  query = tostring(text or "")
  page = 1
  applyFilter()
  render()
end

function onCategoryChange(index, _label)
  categoryIndex = tonumber(index) or 0
  page = 1
  applyFilter()
  render()
end

function onOutputChange(index, label)
  if tonumber(index) == 0 then
    selectedConnectorName = ""
  elseif type(label) == "string" and label ~= "" then
    selectedConnectorName = label
  end
  render()
end

function onTogglePause()
  local kind = selectionLiveKind()
  if kind == "shader" then
    local paused = noctalia.getSetting("wallpaper.shader.paused") == true
    configSet("wallpaper.shader.paused", paused and "false" or "true")
  elseif kind == "sequoia" then
    local still = noctalia.getSetting("wallpaper.sequoia.desktop_motion") == "still"
    configSet("wallpaper.sequoia.desktop_motion", quoted(still and "animated" or "still"))
  end
end

function onStop()
  for _, connector in ipairs(targetConnectors()) do
    local image = previous[connector]
    if image ~= nil and isLive(noctalia.wallpaperPath(connector)) then
      noctalia.setWallpaper(connector, image)
      previous[connector] = nil
    end
  end
  savePrevious()
  render()
end

function onToggleSettings()
  showSettings = not showSettings
  render()
end

function onPrevPage()
  if page > 1 then
    page -= 1
    render()
  end
end

function onNextPage()
  if page < totalPages() then
    page += 1
    render()
  end
end

function onClose()
  panel.close()
end

-- Wallpaper paths are not shell settings, so onConfigChanged does not fire for
-- them, and panels get no update() ticks: the service polls them and publishes
-- a signature here (a tile click lands a moment after its callback, and other
-- tools change wallpapers too).
noctalia.state.watch("paths", function(_)
  render()
end)

-- erebor-modes: the service publishes the mode state; block or unblock at once.
noctalia.state.watch(EreborModes.STATE_KEY, function(_)
  render()
end)
