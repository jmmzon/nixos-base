--!nonstrict
-- Shared by the phone service, bar widget and panel. State "phone" is nil
-- while no phone is connected as hands-free (or `call` is missing), else
-- { address = "...", calls = { { path, state, number, contact }, ... } }.
-- Call states come from PipeWire's telephony API: dialing, alerting, active,
-- held, incoming, waiting.

local M = {}

M.CMD = "/run/current-system/sw/bin/call"
M.CONTACTS = "/run/current-system/sw/bin/call-contacts"
M.PANEL = "janzon/phone:phone-panel"

local function lines(text)
  local out = {}
  for line in string.gmatch(tostring(text or ""), "[^\n]+") do
    table.insert(out, line)
  end
  return out
end

local function fields(line)
  local out = {}
  for field in string.gmatch(line .. "\t", "([^\t]*)\t") do
    table.insert(out, field)
  end
  return out
end

-- Reads `call state` and publishes it.
function M.refresh()
  noctalia.runAsync({ M.CMD, "state" }, function(result)
    if type(result) ~= "table" or result.exitCode ~= 0 then
      noctalia.state.set("phone", nil)
      return
    end
    local phone = nil
    local calls = {}
    for _, line in ipairs(lines(result.stdout)) do
      local f = fields(line)
      if f[1] == "phone" then
        phone = phone or f[2]
      elseif f[1] == "call" then
        table.insert(calls, { path = f[2], state = f[3], number = f[4] or "", contact = f[5] or "" })
      end
    end
    noctalia.state.set("phone", phone and { address = phone, calls = calls } or nil)
  end)
end

-- Runs `call <args...>`; failures show as a notification. Refreshes after.
function M.run(...)
  local args = { M.CMD, ... }
  local what = table.concat({ ... }, " ")
  noctalia.runAsync(args, function(result)
    if type(result) ~= "table" or result.exitCode ~= 0 then
      local err = type(result) == "table" and noctalia.string.trim(tostring(result.stderr)) or tostring(result)
      noctalia.notifyError("Phone", err ~= "" and err or ("call " .. what .. " failed"))
    end
    M.refresh()
  end)
end

-- `call-contacts QUERY` → { { name, label, number }, ... } for the callback.
function M.search(query, callback)
  local args = { M.CONTACTS }
  for word in string.gmatch(query or "", "%S+") do
    table.insert(args, word)
  end
  noctalia.runAsync(args, function(result)
    local rows = {}
    if type(result) == "table" and result.exitCode == 0 then
      for _, line in ipairs(lines(result.stdout)) do
        local f = fields(line)
        if f[3] and f[3] ~= "" then
          table.insert(rows, { name = f[1], label = f[2], number = f[3] })
        end
      end
    end
    callback(rows)
  end)
end

function M.looksLikeNumber(text)
  local compact = string.gsub(text or "", "[%s%-%(%)%./]", "")
  return string.match(compact, "^%+?[%d%*#]+$") ~= nil and #compact >= 3
end

function M.ringing(phone)
  for _, c in ipairs(phone and phone.calls or {}) do
    if c.state == "incoming" or c.state == "waiting" then
      return c
    end
  end
  return nil
end

function M.who(c)
  if c.contact ~= "" then
    return c.contact
  end
  return c.number ~= "" and c.number or "Unknown number"
end

return M
