package.path = (os.getenv("FB_DIR") or ".") .. "/?.lua;" .. package.path
local c = require("common")
local LV = {INFO="INFO",WARNING="WARN",ERROR="ERROR",SEVERE="ERROR",FATAL="FATAL",FAILURE="FATAL"}
function f(tag, ts, record)
  local s = c.line(record)
  local label, node, y, mo, d, h, mi, se, rest = s:match("^([^ ]+) %d+ %d%d%d%d%.%d%d%.%d%d ([^ ]+) (%d%d%d%d)%-(%d%d)%-(%d%d)%-(%d%d)%.(%d%d)%.(%d%d)%.%d%d%d%d%d%d (.*)$")
  if not label then record._bad = "1"; return 1, ts, record end
  if not (node == "-" and (rest:find("^RAS ") or rest:find("^NULL "))) then
    rest = rest:match("^[^ ]+ (.*)$")
    if not rest then record._bad = "1"; return 1, ts, record end
  end
  local ty, comp, lv, msg = rest:match("^([^ ]+) ([^ ]+) ([^ ]+) (.*)$")
  if not ty then
    ty, comp, lv = rest:match("^([^ ]+) ([^ ]+) ([^ ]+)$")
    msg = ""
  end
  local level = lv and LV[lv]
  if not level or (ty ~= "RAS" and ty ~= "NULL") or not c.range(tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se)) then record._bad = "1"; return 1, ts, record end
  if comp == "APP" and c.RANK[level] < c.RANK.ERROR then return -1, ts, record end
  local kv = {node=node}
  if label ~= "-" then kv.alert = label end
  local out = c.finish(y.."-"..mo.."-"..d.."T"..h..":"..mi..":"..se.."Z", level, comp, msg, kv)
  if not out then return -1, ts, record end
  return 1, ts, out
end
