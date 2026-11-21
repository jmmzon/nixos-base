--!nonstrict
-- @include erebor-modes
-- A leaf on the bar while a desktop mode (power-saver) is on; hidden otherwise.
-- The tooltip lists what the mode changed; a click opens the mode panel.

local function render()
  local mode = EreborModes.holding(nil)
  barWidget.setVisible(mode ~= nil)
  if mode == nil then
    return
  end
  barWidget.setGlyph("leaf")
  barWidget.setGlyphColor("primary")
  barWidget.setTooltip(EreborModes.summary(mode))
end

noctalia.state.watch(EreborModes.STATE_KEY, function(_) render() end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("janzon/toggles:mode-panel")
end

render()
