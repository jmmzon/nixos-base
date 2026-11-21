--!nonstrict
-- @include erebor-modes
-- Bar widget for the live wallpaper picker. Click: open the picker.
-- Right-click: stop or restart the animation of what the outputs show — shader
-- wallpapers ([wallpaper.shader] paused) or Sequoia (its desktop motion). The
-- icon shows a pause mark while the live wallpaper on screen is stopped, and a
-- leaf while power-saver (erebor-modes) holds it; right-click then opens the picker.

local glyph = noctalia.getConfig("glyph")

-- erebor-modes items that stop the animation (modules/erebor-modes.nix).
local MODE_ITEMS = { "wallpaper-shader", "wallpaper-sequoia", "wallpaper-engine" }

-- "shader" when any output shows a shader, else "sequoia" when any shows Sequoia, else nil.
local function liveKind()
  local kind = nil
  for _, output in ipairs(noctalia.outputs() or {}) do
    local path = noctalia.wallpaperPath(output.name)
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

local function stopped(kind)
  if kind == "shader" then
    return noctalia.getSetting("wallpaper.shader.paused") == true
  elseif kind == "sequoia" then
    return noctalia.getSetting("wallpaper.sequoia.desktop_motion") == "still"
  end
  return false
end

local function render()
  local held = EreborModes.holding(MODE_ITEMS)
  if held ~= nil then
    barWidget.setGlyph("leaf")
    barWidget.setTooltip(noctalia.tr("title") .. " · " .. string.format(noctalia.tr("held_tooltip"), held.label))
    return
  end
  local kind = liveKind()
  local isStopped = stopped(kind)
  barWidget.setGlyph(isStopped and "player-pause" or glyph)
  local tooltip = noctalia.tr("title")
  if isStopped then
    tooltip = tooltip .. " · " .. noctalia.tr("paused_note")
  end
  if kind ~= nil then
    tooltip = tooltip .. "\n" .. noctalia.tr(isStopped and "right_click_resume" or "right_click_pause")
  end
  barWidget.setTooltip(tooltip)
end

local function configSet(key, value)
  noctalia.runAsync({ "noctalia", "msg", "config-set", key, value }, function(result)
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("config_failed") .. ": " .. tostring(result.stderr))
    end
    render()
  end)
end

-- Wallpaper paths are not shell settings: update() (every 250 ms by default) keeps the icon current.
function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel("janzon/live-wallpaper:picker")
end

function onRightClick()
  if EreborModes.holding(MODE_ITEMS) ~= nil then
    noctalia.togglePanel("janzon/live-wallpaper:picker")
    return
  end
  local kind = liveKind()
  if kind == "shader" then
    configSet("wallpaper.shader.paused", stopped(kind) and "false" or "true")
  elseif kind == "sequoia" then
    configSet("wallpaper.sequoia.desktop_motion", stopped(kind) and '"animated"' or '"still"')
  end
end

render()
