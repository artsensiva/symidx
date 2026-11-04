package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
function f(tag, ts, record)
  local s = c.line(record)
  local y, mo, d, h, mi, se, pid, level, comp, msg = s:match("^(%d%d)(%d%d)(%d%d) (%d%d)(%d%d)(%d%d) (%d+) (%u+) ([^ ]-): (.*)$")
  if not y or not c.RANK[level] or level == "NOTICE" or comp == "" then record._bad = "1"; return 1, ts, record end
  if not c.range(tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se)) then record._bad = "1"; return 1, ts, record end
  local kv = {pid=pid}
  local n = (" " .. msg):match(" blk_(%-?%d*)")
  if n and n:find("^%-?%d+$") then kv.blk = "blk_" .. n end
  local out = c.finish("20"..y.."-"..mo.."-"..d.."T"..h..":"..mi..":"..se.."Z", level, comp, msg, kv)
  if not out then return -1, ts, record end
  return 1, ts, out
end
