package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
local WD = {Mon=1,Tue=1,Wed=1,Thu=1,Fri=1,Sat=1,Sun=1}
local LV = {emerg="FATAL",alert="FATAL",crit="FATAL",error="ERROR",warn="WARN",notice="NOTICE",info="INFO",debug="DEBUG"}
function f(tag, ts, record)
  local s = c.line(record)
  local w, mon, d, h, mi, se, y, l, msg = s:match("^%[(%a%a%a) (%a%a%a) (%d%d) (%d%d):(%d%d):(%d%d) (%d%d%d%d)%] %[(%a+)%] (.*)$")
  local mo = mon and c.MONTH[mon]
  local level = l and LV[l]
  if not mo or not WD[w] or not level then record._bad = "1"; return 1, ts, record end
  if not c.range(tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se)) then record._bad = "1"; return 1, ts, record end
  local out = c.finish(y.."-"..mo.."-"..d.."T"..h..":"..mi..":"..se.."Z", level, "httpd", msg, {})
  if not out then return -1, ts, record end
  return 1, ts, out
end
