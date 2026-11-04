package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
function f(tag, ts, r)
  local msg = r.msg or ""
  local mo = c.MONTH[r.mon]
  local year = tonumber(mo) >= 7 and "2017" or "2018"
  local level = "INFO"
  if msg:find("^error: ") then level = "ERROR" elseif msg:find("^fatal: ") then level = "FATAL"
  elseif msg:find("^Failed ") or msg:find("^Invalid user ") or msg:find("^reverse mapping ") then level = "WARN" end
  local dd = r.d:gsub(" ", "0")
  return 1, ts, c.record(year.."-"..mo.."-"..dd.."T"..r.h..":"..r.mi..":"..r.se.."Z", level, r.prog, msg, {host=r.host, pid=r.pid})
end
