--!nonstrict
-- Phone panel. During a call: who it is, Answer / Decline while it rings,
-- Hang up, and a keypad for tones. Otherwise: a search over the contacts
-- KDE Connect syncs (name or number); a click dials.
local phone = require("./phone_lib.luau")

local MAX_ROWS = 200

local query = ""
local rows = {}
local searchSeq = 0
local keypad = false
local tones = ""

local render

local function search()
  searchSeq += 1
  local seq = searchSeq
  phone.search(query, function(found)
    if seq ~= searchSeq then
      return -- a newer query is on its way
    end
    rows = found
    render()
  end)
end

local function dial(number)
  phone.run(number)
  query = ""
  keypad = false
  tones = ""
  search()
end

local function callStateText(c)
  local states = {
    dialing = "Calling…", alerting = "Ringing…", active = "In call",
    held = "On hold", incoming = "Incoming call", waiting = "Call waiting",
  }
  local text = states[c.state] or c.state
  if c.contact ~= "" and c.number ~= "" then
    text ..= " · " .. c.number
  end
  return text
end

local function callCard(c)
  local ringing = c.state == "incoming" or c.state == "waiting"
  local buttons = {}
  if ringing then
    table.insert(buttons, ui.button({ text = "Answer", glyph = "phone", variant = "primary",
      onClick = function() phone.run("answer") end }))
    table.insert(buttons, ui.button({ text = "Decline", glyph = "phone-end", variant = "destructive",
      onClick = function() phone.run("hangup") end }))
  else
    table.insert(buttons, ui.button({ glyph = "dialpad", variant = keypad and "secondary" or "ghost",
      tooltip = "Keypad", onClick = function()
        keypad = not keypad
        render()
      end }))
    table.insert(buttons, ui.button({ text = "Hang up", glyph = "phone-end", variant = "destructive",
      onClick = function() phone.run("hangup") end }))
  end
  return ui.column({ gap = 10, padding = 12, radius = 12, fill = "surface_container_high" }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = ringing and "phone-ringing" or "phone-calling", size = 22,
        color = ringing and "error" or "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = phone.who(c), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
        ui.label({ text = callStateText(c), fontSize = 12, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ gap = 8, justify = "end" }, buttons),
  })
end

local function keypadGrid()
  local keys = { { "1", "2", "3" }, { "4", "5", "6" }, { "7", "8", "9" }, { "*", "0", "#" } }
  local grid = {}
  for _, row in ipairs(keys) do
    local cells = {}
    for _, key in ipairs(row) do
      table.insert(cells, ui.button({ text = key, variant = "outline", flexGrow = 1, onClick = function()
        tones ..= key
        phone.run("tones", key)
        render()
      end }))
    end
    table.insert(grid, ui.row({ gap = 6 }, cells))
  end
  table.insert(grid, 1, ui.label({ text = tones ~= "" and tones or "Tones go to the call as you press",
    fontSize = tones ~= "" and 18 or 12, textAlign = "center",
    color = tones ~= "" and "on_surface" or "on_surface_variant" }))
  return ui.column({ gap = 6 }, grid)
end

local function contactRow(r)
  return ui.row({ gap = 10, align = "center", paddingH = 8, paddingV = 6, radius = 8,
    tooltip = "Call " .. r.number, onClick = function() dial(r.number) end }, {
    ui.glyph({ name = "user", size = 18, color = "on_surface_variant" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = r.name, fontSize = 14, maxLines = 1 }),
      ui.label({ text = r.label .. " · " .. r.number, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.glyph({ name = "phone", size = 16, color = "primary" }),
  })
end

local function searchView()
  local list = {}
  if phone.looksLikeNumber(query) then
    table.insert(list, ui.button({ text = "Call " .. query, glyph = "phone", variant = "primary",
      onClick = function() dial(query) end }))
  end
  for i, r in ipairs(rows) do
    if i > MAX_ROWS then
      table.insert(list, ui.label({ text = (#rows - MAX_ROWS) .. " more — type to narrow down",
        fontSize = 12, color = "on_surface_variant", textAlign = "center" }))
      break
    end
    table.insert(list, contactRow(r))
  end
  if #list == 0 then
    table.insert(list, ui.label({
      text = query == "" and "No contacts yet — turn on Contacts synchronizer in KDE Connect on the phone"
        or "No contact matches",
      fontSize = 12, color = "on_surface_variant", textAlign = "center",
    }))
  end
  return {
    ui.input({ key = "search", value = query, placeholder = "Name or number", focus = true,
      submitOnEnter = true,
      onChange = function(text)
        query = tostring(text or "")
        search()
        render()
      end,
      onSubmit = function(text)
        query = tostring(text or query)
        if phone.looksLikeNumber(query) then
          dial(query)
        elseif rows[1] then
          dial(rows[1].number)
        end
      end }),
    ui.scroll({ flexGrow = 1, gap = 2 }, list),
  }
end

render = function()
  local state = noctalia.state.get("phone")
  local body = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "phone", size = 20, color = state and "primary" or "on_surface_variant" }),
      ui.label({ text = "Phone", fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = state and "Connected" or "Not connected", fontSize = 12, color = "on_surface_variant" }),
    }),
  }
  if state == nil then
    table.insert(body, ui.label({
      text = "Connect the phone over Bluetooth to call from here.",
      fontSize = 12, color = "on_surface_variant",
    }))
  elseif #state.calls > 0 then
    for _, c in ipairs(state.calls) do
      table.insert(body, callCard(c))
    end
    if keypad and not phone.ringing(state) then
      table.insert(body, keypadGrid())
    end
  else
    for _, node in ipairs(searchView()) do
      table.insert(body, node)
    end
  end
  panel.render(ui.column({ gap = 12, padding = 16, flexGrow = 1 }, body))
end

noctalia.state.watch("phone", function(state)
  if state == nil or #state.calls == 0 then
    keypad = false
    tones = ""
  end
  render()
end)

function onOpen()
  noctalia.state.set("phonePanelOpen", true)
  phone.refresh()
  search()
  render()
end

function onClose()
  noctalia.state.set("phonePanelOpen", false)
end
