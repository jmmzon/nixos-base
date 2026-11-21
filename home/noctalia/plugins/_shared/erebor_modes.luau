-- erebor-modes for Noctalia plugins (SYS-122). Plugin scripts have no
-- `require`: modules/noctalia.nix inlines this file where a script has the line
-- `-- @include erebor-modes`, so every surface shows a mode the same way.
--
-- The engine (`erebor-modes`, modules/erebor-modes.nix) writes
-- ~/.local/state/erebor-modes/state.json whenever a mode starts or ends. A
-- plugin's service calls EreborModes.poll() from update() and publishes the
-- state under noctalia.state "ereborModes"; panels (which get no update ticks)
-- and widgets watch that key.

local EreborModes = {}

EreborModes.STATE_KEY = "ereborModes"

local function stateFile()
  local base = noctalia.getenv("XDG_STATE_HOME")
  if base == nil or base == "" then
    base = (noctalia.getenv("HOME") or "") .. "/.local/state"
  end
  return base .. "/erebor-modes/state.json"
end

local lastRaw = nil

-- Service side: read the state file and publish it when it changed.
function EreborModes.poll()
  local raw = noctalia.readFile(stateFile())
  if type(raw) ~= "string" then
    raw = ""
  end
  if raw == lastRaw then
    return
  end
  lastRaw = raw
  local decoded = raw ~= "" and noctalia.json.decode(raw) or nil
  noctalia.state.set(EreborModes.STATE_KEY, type(decoded) == "table" and decoded or nil)
end

-- The active mode that holds any of `itemIds`, as { id, label, leave, items =
-- { labels of what it changed } }. An item holds while the mode covers it,
-- applied or skipped (e.g. Wallpaper Engine not running yet, so a pick would
-- start it); only a value changed by hand (or a failed item) releases it.
-- With no `itemIds`, any active mode is returned.
function EreborModes.holding(itemIds)
  local state = noctalia.state.get(EreborModes.STATE_KEY)
  if type(state) ~= "table" or type(state.modes) ~= "table" or #state.modes == 0 then
    return nil
  end
  local items = type(state.items) == "table" and state.items or {}
  local kinds = type(state.mode_kinds) == "table" and state.mode_kinds or {}
  local modeId = nil
  if itemIds == nil then
    -- Toggle modes (Reduce transparency) have their own button, not the leaf.
    for _, id in ipairs(state.modes) do
      if modeId == nil and kinds[id] ~= "toggle" then
        modeId = id
      end
    end
  end
  for _, id in ipairs(itemIds or {}) do
    local item = items[id]
    if modeId == nil and type(item) == "table" and (item.status == "applied" or item.status == "skipped") then
      modeId = item.mode
    end
  end
  if modeId == nil then
    return nil
  end
  local labels = {}
  for _, item in pairs(items) do
    if type(item) == "table" and item.status == "applied" and item.mode == modeId then
      table.insert(labels, tostring(item.label))
    end
  end
  table.sort(labels)
  local modeLabels = type(state.mode_labels) == "table" and state.mode_labels or {}
  return {
    id = modeId,
    label = tostring(modeLabels[modeId] or modeId),
    leave = type(state.leave) == "table" and state.leave or nil,
    items = labels,
  }
end

-- Panel side: the card that replaces a panel's body while `mode` holds it.
-- `what` says what is suspended ("Animated wallpapers"); nil gives the plain
-- "<mode> is on" card of the mode panel. The buttons call the global callbacks
-- below, so a panel that includes this gets them for free.
function EreborModes.card(mode, what, closeButton)
  local children = {}
  if closeButton then
    table.insert(children, ui.row({ justify = "end" }, {
      ui.button({ glyph = "close", variant = "ghost", onClick = "onClose" }),
    }))
  end
  table.insert(children, ui.spacer({ flexGrow = 1 }))
  table.insert(children, ui.glyph({ name = "leaf", size = 48, color = "primary" }))
  table.insert(children, ui.label({
    text = what ~= nil and `{what} are paused by {mode.label}` or `{mode.label} is on`,
    fontSize = 18,
    fontWeight = "bold",
    color = "on_surface",
    textAlign = "center",
  }))
  table.insert(children, ui.label({
    text = `{mode.label} changed: ` .. table.concat(mode.items, " · "),
    fontSize = 12,
    color = "on_surface_variant",
    textAlign = "center",
    maxWidth = 560,
  }))
  table.insert(children, ui.label({
    text = "Everything comes back when you leave it.",
    fontSize = 12,
    color = "on_surface_variant",
    textAlign = "center",
  }))
  local buttons = {}
  if mode.leave ~= nil then
    table.insert(buttons, ui.button({
      text = tostring(mode.leave.label or "Leave"),
      glyph = "bolt",
      onClick = "onEreborModesLeave",
    }))
  end
  for i, offer in ipairs(EreborModes.offers()) do
    if i <= 3 then
      table.insert(buttons, ui.button({
        text = tostring(offer.action),
        glyph = "plus",
        variant = "outline",
        onClick = "onEreborModesOffer" .. i,
      }))
    end
  end
  table.insert(buttons, ui.button({
    text = "Power profiles…",
    glyph = "adjustments",
    variant = "outline",
    onClick = "onEreborModesProfiles",
  }))
  table.insert(children, ui.row({ gap = 12, justify = "center" }, buttons))
  table.insert(children, ui.spacer({ flexGrow = 1 }))
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, children)
end

-- Bar widgets: the mode's changes as one line, for tooltips.
function EreborModes.summary(mode)
  return `{mode.label}: ` .. table.concat(mode.items, " · ")
end

function onEreborModesLeave()
  local state = noctalia.state.get(EreborModes.STATE_KEY)
  local leave = type(state) == "table" and state.leave or nil
  if type(leave) ~= "table" or type(leave.command) ~= "table" then
    return
  end
  noctalia.runAsync(leave.command, function(result)
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError(tostring(leave.label), tostring(result.stderr))
    end
  end)
end

function onEreborModesProfiles()
  noctalia.runAsync({ "noctalia", "msg", "panel-open", "control-center" }, function(_) end)
end

-- Offered extras of the active modes (e.g. "Reduce transparency too"), sorted
-- by id: { id, action }.
function EreborModes.offers()
  local state = noctalia.state.get(EreborModes.STATE_KEY)
  local out = {}
  if type(state) == "table" and type(state.offers) == "table" then
    for id, offer in pairs(state.offers) do
      if type(offer) == "table" then
        table.insert(out, { id = id, action = offer.action or offer.label or id })
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

local function takeOffer(i)
  local offer = EreborModes.offers()[i]
  if offer == nil then
    return
  end
  noctalia.runAsync({ "erebor-modes", "request", offer.id }, function(result)
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError(tostring(offer.action), tostring(result.stderr))
    end
  end)
end

function onEreborModesOffer1() takeOffer(1) end
function onEreborModesOffer2() takeOffer(2) end
function onEreborModesOffer3() takeOffer(3) end

-- Whether a toggle mode (e.g. "reduce-transparency") is on.
function EreborModes.isOn(modeId)
  local state = noctalia.state.get(EreborModes.STATE_KEY)
  if type(state) ~= "table" or type(state.modes) ~= "table" then
    return false
  end
  for _, id in ipairs(state.modes) do
    if id == modeId then
      return true
    end
  end
  return false
end

-- Switch a toggle mode; `done(on)` gets the new state.
function EreborModes.toggle(modeId, done)
  noctalia.runAsync({ "erebor-modes", "toggle", modeId }, function(result)
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.notifyError(modeId, tostring(result.stderr))
    end
    EreborModes.poll()
    if done ~= nil then
      done(EreborModes.isOn(modeId))
    end
  end)
end
