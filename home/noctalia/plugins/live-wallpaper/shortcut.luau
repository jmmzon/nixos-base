--!nonstrict
-- Tile in the control center that opens the live wallpaper picker.

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("sparkles")
end

render()

function onClick()
  noctalia.togglePanel("janzon/live-wallpaper:picker")
end
