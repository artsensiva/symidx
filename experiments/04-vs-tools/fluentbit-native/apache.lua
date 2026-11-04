package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
local LV = {emerg="FATAL",alert="FATAL",crit="FATAL",error="ERROR",warn="WARN",notice="NOTICE",info="INFO"}
function f(tag, ts, r)
  return 1, ts, c.record(r.y.."-"..c.MONTH[r.mon].."-"..r.d.."T"..r.h..":"..r.mi..":"..r.se.."Z", LV[r.l], "httpd", r.msg or "", {})
end
