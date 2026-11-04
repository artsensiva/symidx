package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
function f(tag, ts, record)
  local s = c.line(record)
  local mon, d, h, mi, se, host, prog, pid, msg = s:match("^(%a%a%a) ([ %d]%d) (%d%d):(%d%d):(%d%d) ([^ ]+) ([^ %[]+)%[(%d+)%]: (.*)$")
  local mo = mon and c.MONTH[mon]
  if not mo then record._bad = "1"; return 1, ts, record end
  local dd = d:gsub(" ", "0")
  if not c.range(tonumber(mo), tonumber(dd), tonumber(h), tonumber(mi), tonumber(se)) then record._bad = "1"; return 1, ts, record end
  local year = tonumber(mo) >= 7 and "2017" or "2018"
  local level = "INFO"
  if msg:find("^error: ") then level = "ERROR" elseif msg:find("^fatal: ") then level = "FATAL"
  elseif msg:find("^Failed ") or msg:find("^Invalid user ") or msg:find("^reverse mapping ") then level = "WARN" end
  local out = c.finish(year.."-"..mo.."-"..dd.."T"..h..":"..mi..":"..se.."Z", level, prog, msg, {host=host, pid=pid})
  if not out then return -1, ts, record end
  return 1, ts, out
end
