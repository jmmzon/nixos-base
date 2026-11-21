--!nonstrict
-- @include erebor-modes
-- Publishes erebor-modes' state (state key "ereborModes") for the mode widget
-- and panel and the ambilight button. Panels get no update ticks.

noctalia.setUpdateInterval(1000)

function update()
  EreborModes.poll()
end

EreborModes.poll()
