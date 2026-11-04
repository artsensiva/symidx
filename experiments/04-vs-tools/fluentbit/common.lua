-- Experiment 2's transform, shared by the three format scripts.
local M = {}
local RANK = {TRACE=0, DEBUG=1, INFO=2, NOTICE=3, WARN=4, ERROR=5, FATAL=6}
local SEV = {FATAL=2, ERROR=3, WARN=4, NOTICE=5, INFO=6, DEBUG=7, TRACE=7}
M.RANK = RANK
M.MONTH = {Jan="01",Feb="02",Mar="03",Apr="04",May="05",Jun="06",Jul="07",Aug="08",Sep="09",Oct="10",Nov="11",Dec="12"}

local function ip_run(run)
  if not run:find("^%d") then return nil end
  local core, dots = run:match("^(.-)(%.*)$")
  if core:find("^%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?$") then return "<ip>" .. dots end
  return nil
end

function M.range(mo, d, h, mi, s)
  return mo >= 1 and mo <= 12 and d >= 1 and d <= 31 and h <= 23 and mi <= 59 and s <= 59
end

-- kv is a table already holding the format's pairs. Returns the output record, or nil if it's filtered out.
function M.finish(ts, level, component, msg, kv)
  local min = (component == "dfs.DataNode$PacketResponder" or component == "dfs.FSDataset") and 4 or 2
  if RANK[level] < min then return nil end
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

-- tail has already removed one trailing CR, which is all the task removes.
function M.line(record)
  return record["log"]
end

return M
