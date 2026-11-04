package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
function f(tag, ts, r)
  local msg = r.msg or ""
  local kv = {pid=r.pid}
  local n = (" " .. msg):match(" blk_(%-?%d*)")
  if n and n:find("^%-?%d+$") then kv.blk = "blk_" .. n end
  return 1, ts, c.record("20"..r.y.."-"..r.mo.."-"..r.d.."T"..r.h..":"..r.mi..":"..r.se.."Z", r.level, r.component, msg, kv)
end
