--!nonstrict
-- @include erebor-modes
-- Bar widget that opens the Wallpaper Engine picker; a leaf while power-saver
-- (erebor-modes) covers the engine.

local glyph = noctalia.getConfig("glyph")

-- erebor-modes item that pauses the engine (modules/erebor-modes.nix).
local MODE_ITEMS = { "wallpaper-engine" }

local function render()
  local held = EreborModes.holding(MODE_ITEMS)
  barWidget.setGlyph(held ~= nil and "leaf" or glyph)
  barWidget.setTooltip(noctalia.tr("title") .. (held ~= nil and (" · " .. string.format(noctalia.tr("held_tooltip"), held.label)) or ""))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("janzon/wallpaper-engine:picker")
end

render()
