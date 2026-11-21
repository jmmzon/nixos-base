--!nonstrict
-- @include erebor-modes
-- Reduce transparency (erebor-modes toggle, SYS-122): lit while on. A click
-- switches it; apps, Noctalia's surfaces and Darkly then stay at least 0.9
-- opaque (the bars 0.75), glass and blur stay.

local MODE = "reduce-transparency"
local busy = false
local pending = nil -- shown at once after a click, until the state confirms it

local function render()
  local on = EreborModes.isOn(MODE)
  if pending ~= nil then on = pending end
  barWidget.setGlyph("contrast")
  barWidget.setGlyphColor(on and "primary" or "on_surface_variant")
  barWidget.setTooltip(on and "Reduce transparency on — click to turn off"
    or "Reduce transparency off — click to turn on")
end

noctalia.state.watch(EreborModes.STATE_KEY, function(_)
  if not busy then pending = nil end
  render()
end)

function onClick()
  if busy then return end
  busy = true
  pending = not EreborModes.isOn(MODE)
  render()
  EreborModes.toggle(MODE, function(_)
    busy = false
    pending = nil
    render()
  end)
end

render()
