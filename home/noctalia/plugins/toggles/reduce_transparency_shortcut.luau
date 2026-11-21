--!nonstrict
-- @include erebor-modes
-- Control-center tile for Reduce transparency (erebor-modes toggle): a click
-- switches it.

local MODE = "reduce-transparency"

local function render()
  shortcut.setLabel("Opaque UI") -- short: tile labels are cut at ~10 characters
  shortcut.setIcon("contrast", "contrast")
  shortcut.setActive(EreborModes.isOn(MODE))
end

noctalia.state.watch(EreborModes.STATE_KEY, function(_) render() end)
render()

function onClick()
  EreborModes.toggle(MODE, function(_) render() end)
end
