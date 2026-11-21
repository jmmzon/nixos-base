--!nonstrict
-- @include erebor-modes
-- IPC for keybinds and scripts:
--   noctalia msg plugin janzon/live-wallpaper:service all <event> [payload]
-- Events: toggle / open (the picker), pause, resume, toggle-pause (shader
-- wallpapers, [wallpaper.shader] paused), set <path> (a live wallpaper on every
-- output, e.g. "set shader:kde/Shaders/1993" or "set sequoia:"). It also
-- publishes the wallpaper paths for the panel (state key "paths") and applies a
-- value typed into the panel's speed box once typing pauses (state key
-- "speedPending"; the panel has no timers), and erebor-modes' state (state key
-- "ereborModes"): while power-saver holds the animation, resume is refused.

local PANEL = "janzon/live-wallpaper:picker"

-- erebor-modes items that stop the animation (modules/erebor-modes.nix).
local MODE_ITEMS = { "wallpaper-shader", "wallpaper-sequoia", "wallpaper-engine" }

-- The panel cannot poll (panels get no update() ticks), so this publishes the
-- outputs' wallpaper paths for it to watch.
local lastPaths = nil

local function pathsSignature()
  local parts = {}
  for _, output in ipairs(noctalia.outputs() or {}) do
    table.insert(parts, output.name .. "=" .. tostring(noctalia.wallpaperPath(output.name)))
  end
  return table.concat(parts, ";")
end

local function configSet(key, value)
  noctalia.runAsync({ "noctalia", "msg", "config-set", key, value }, function(result)
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("config_failed") .. ": " .. tostring(result.stderr))
    end
  end)
end

-- The panel's speed box: apply a typed value once it has not changed for a moment.
local SPEED_SETTLE_MS = 700

local function applyPendingSpeed()
  local pending = noctalia.state.get("speedPending")
  if type(pending) ~= "table" or type(pending.at) ~= "number" then
    return
  end
  if noctalia.nowMs() - pending.at < SPEED_SETTLE_MS then
    return
  end
  noctalia.state.set("speedPending", nil)
  local value = tonumber((tostring(pending.text or ""):gsub(",", "."):gsub("[x×%s]", "")))
  if value == nil or type(pending.key) ~= "string" then
    return
  end
  value = math.max(tonumber(pending.min) or 0, math.min(tonumber(pending.max) or 4, value))
  configSet(pending.key, string.format("%.4f", value))
end

function update()
  applyPendingSpeed()
  EreborModes.poll()
  local signature = pathsSignature()
  if signature ~= lastPaths then
    lastPaths = signature
    noctalia.state.set("paths", signature)
  end
end

noctalia.setUpdateInterval(500)

function onIpc(event, payload)
  if event == "toggle" or event == "open" then
    noctalia.togglePanel(PANEL)
  elseif (event == "resume" or event == "toggle-pause") and EreborModes.holding(MODE_ITEMS) ~= nil then
    -- A mode (power-saver) holds the animation; leaving it resumes it.
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("held_by_mode"))
  elseif event == "pause" then
    configSet("wallpaper.shader.paused", "true")
  elseif event == "resume" then
    configSet("wallpaper.shader.paused", "false")
  elseif event == "toggle-pause" then
    configSet("wallpaper.shader.paused", noctalia.getSetting("wallpaper.shader.paused") == true and "false" or "true")
  elseif event == "set" then
    local path = tostring(payload or ""):match("^%s*(%S+)")
    if path ~= nil and (path:sub(1, 7) == "shader:" or path:sub(1, 8) == "sequoia:") then
      noctalia.setWallpaper(path)
    else
      noctalia.log("set: expected a shader: or sequoia: path, got '" .. tostring(payload) .. "'")
    end
  end
end
