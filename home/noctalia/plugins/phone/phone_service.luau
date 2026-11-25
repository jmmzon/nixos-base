--!nonstrict
-- Polls the phone every 2 s; opens the panel once when a call starts ringing
-- (unless it is already open).
local phone = require("./phone_lib.luau")

noctalia.setUpdateInterval(2000)

local wasRinging = false

noctalia.state.watch("phone", function(state)
  local ringing = phone.ringing(state) ~= nil
  if ringing and not wasRinging and not noctalia.state.get("phonePanelOpen") then
    noctalia.togglePanel(phone.PANEL)
  end
  wasRinging = ringing
end)

function update()
  phone.refresh()
end

phone.refresh()
