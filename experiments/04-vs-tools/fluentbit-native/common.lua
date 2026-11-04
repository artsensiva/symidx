-- What's left for Lua once native parsers and grep have run: the timestamp, redaction, the pair list, and sev.
local M = {}
local SEV = {FATAL=2, ERROR=3, WARN=4, NOTICE=5, INFO=6, DEBUG=7, TRACE=7}
M.MONTH = {Jan="01",Feb="02",Mar="03",Apr="04",May="05",Jun="06",Jul="07",Aug="08",Sep="09",Oct="10",Nov="11",Dec="12"}

local function ip_run(run)
  if not run:find("^%d") then return nil end
  local core, dots = run:match("^(.-)(%.*)$")
  if core:find("^%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?$") then return "<ip>" .. dots end
  return nil
end

function M.record(ts, level, component, msg, kv)
  local red = msg
  if msg:find("%d%.%d") then red = msg:gsub("%f[%d.][%d.]+", ip_run) end
  if red:find("=", 1, true) then
    for tok in red:gmatch("[^ ]+") do
      local k, v = tok:match("^([%w_.-]+)=(.*)$")
      if k then kv[k] = v end
    end
  end
  return {ts=ts, level=level, sev=SEV[level], component=component, msg=red, kv=kv}
end

return M
