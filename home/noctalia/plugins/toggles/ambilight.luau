--!nonstrict
-- @include erebor-modes
-- Ambilight (my.ambilight, WLED + HyperHDR): a click switches the LEDs with
-- ambilight-toggle, the same steps as the dashboard's buttons. The glyph is lit
-- when on and dimmed when off. Hidden while WLED does not answer or the
-- command is missing (machines without ambilight). The tooltip says when
-- power-saver (erebor-modes, state from the modes service) has dimmed it.

local CMD = "ambilight-toggle"
local state = nil -- "on", "off" or nil (unknown)
local busy = false

local function render()
  barWidget.setVisible(state ~= nil)
  barWidget.setGlyph("bulb")
  local dimmed = EreborModes.holding({ "ambilight" })
  local note = dimmed ~= nil and ("\nDimmed by " .. dimmed.label .. " until you leave it") or ""
  if state == "on" then
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip("Ambilight on — click to turn off" .. note)
  else
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip("Ambilight off — click to turn on" .. note)
  end
end

local function poll()
  noctalia.runAsync({ CMD, "status" }, function(result)
    if type(result) ~= "table" or result.exitCode ~= 0 then
      state = nil
    else
      local out = noctalia.string.trim(tostring(result.stdout))
      state = (out == "on" or out == "off") and out or nil
    end
    render()
  end)
end

-- Polls so the glyph follows the dashboard too.
local ticks = 0
function update()
  ticks = ticks + 1
  if ticks >= 12 and not busy then -- update() runs every 250 ms: poll every 3 s
    ticks = 0
    poll()
  end
end

function onClick()
  if busy then
    return
  end
  busy = true
  -- Show the new state at once; the poll after the command confirms it.
  if state ~= nil then
    state = state == "on" and "off" or "on"
    render()
  end
  noctalia.runAsync({ CMD, "toggle" }, function(result)
    busy = false
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError("Ambilight", "ambilight-toggle failed: " .. tostring(result.stderr))
    end
    poll()
  end)
end

render()
poll()
