--!nonstrict
-- @include erebor-modes
-- The mode panel: what the active mode (power-saver) changed, and the buttons
-- to leave it or open the power profiles. Closes itself when the mode ends.

local function render()
  local mode = EreborModes.holding(nil)
  if mode == nil then
    panel.close()
    return
  end
  panel.render(ui.column({ gap = 12, padding = 16 }, { EreborModes.card(mode, nil, false) }))
end

noctalia.state.watch(EreborModes.STATE_KEY, function(_) render() end)

function onOpen()
  render()
end

function onClose()
  panel.close()
end
