--!nonstrict
-- Bar button: hidden while no phone is connected. Plain phone when idle,
-- lit while a call is up, ringing while one comes in. Click opens the panel,
-- right-click hangs up.
local phone = require("./phone_lib.luau")

local function render(state)
  barWidget.setVisible(state ~= nil)
  if state == nil then
    return
  end
  local ring = phone.ringing(state)
  local current = state.calls[1]
  if ring then
    barWidget.setGlyph("phone-ringing")
    barWidget.setGlyphColor("error")
    barWidget.setTooltip("Incoming call: " .. phone.who(ring) .. " — click to answer or decline")
  elseif current then
    barWidget.setGlyph("phone-calling")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(current.state .. ": " .. phone.who(current) .. " — right-click to hang up")
  else
    barWidget.setGlyph("phone")
    barWidget.setGlyphColor("on_surface")
    barWidget.setTooltip("Phone " .. state.address .. " — click to call someone")
  end
end

noctalia.state.watch("phone", render)
render(noctalia.state.get("phone"))

function onClick()
  noctalia.togglePanel(phone.PANEL)
end

function onRightClick()
  local state = noctalia.state.get("phone")
  if state and #state.calls > 0 then
    phone.run("hangup")
  end
end
