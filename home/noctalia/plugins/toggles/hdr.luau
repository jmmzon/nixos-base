--!nonstrict
-- HDR on DP-1 (Umbriel). Off at every login; a click switches it with
-- umbriel-hdr-toggle (same as Ctrl+Alt+Super+Insert). The glyph is lit when
-- HDR is on and dimmed when off. Hidden outside Umbriel (status fails).

local CMD = "umbriel-hdr-toggle"
local state = nil -- "on", "off" or nil (unknown / not Umbriel)
local busy = false

local function render()
  barWidget.setVisible(state ~= nil)
  barWidget.setGlyph("hdr")
  if state == "on" then
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip("HDR on — click to turn off")
  else
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip("HDR off — click to turn on")
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

-- Polls so the glyph follows the keyboard shortcut too.
local ticks = 0
function update()
  ticks = ticks + 1
  if ticks >= 8 and not busy then -- update() runs every 250 ms: poll every 2 s
    ticks = 0
    poll()
  end
end

function onClick()
  if busy then
    return
  end
  busy = true
  noctalia.runAsync({ CMD }, function(result)
    busy = false
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError("HDR", "umbriel-hdr-toggle failed: " .. tostring(result.stderr))
    end
    poll()
  end)
end

render()
poll()
