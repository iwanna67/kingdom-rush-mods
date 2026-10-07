--[[----------------------------------------------------------------------------
  kr_gold_55555.lua —— 金币插件（v1.0，2026-10-07）

  作用：**局内一拿到金币（含进关卡的起始金币），立刻把金币跳到 55555。**
        花掉之后再捡到金币，会再跳回 55555。

  怎么判断"拿到金币"：每帧比较 store.player_gold 和上一帧的值
      gold > 上一帧   -> 拿到金币 -> 把 player_gold 设成 CFG.gold
      gold < 上一帧   -> 花掉了   -> 只记录，不动它（所以花钱是有效的，不会瞬间回满）
  进关卡那一下（起始金币 800 之类）默认也算"拿到金币"，所以一进关卡就是 55555；
  想改成"必须自己捡到金币才跳"：把 CFG.trigger_on_enter 设成 false。

  数据来源：game.store.player_gold（与 KRAUTO/控制台用的同一个字段）
  日志：%APPDATA%\kingdom_rush\kr_gold_55555_log.txt
  开关：游戏里按 F9 临时开/关

  说明：这个插件只改内存里的数字，不写存档文件；退出游戏不会留下痕迹。
------------------------------------------------------------------------------]]

local M = {}
M.version = "1.0"

local CFG = {
  gold            = 55555,   -- 要跳到的金币数
  trigger_on_enter = true,   -- 进关卡（起始金币）就跳；false = 只在自己捡到金币时跳
  pin             = false,   -- true = 每帧都把金币顶回 >= gold（等于无限钱，购买会被立刻补回）
  hotkey          = "f9",
  log_file        = "kr_gold_55555_log.txt",
  echo            = true,
}
M.cfg = CFG

-- ------------------------------------------------------------------ 日志
local buf, ts = {}, 0
local function flush()
  if #buf == 0 then return end
  local text = table.concat(buf, "\n") .. "\n"
  buf = {}
  local ok, F = pcall(function() return love and love.filesystem end)
  if not ok or type(F) ~= "table" then return end
  pcall(function()
    if F.append then F.append(CFG.log_file, text)
    else F.write(CFG.log_file, (F.read(CFG.log_file) or "") .. text) end
  end)
end

local function klog(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  if CFG.echo then pcall(print, "[KRGOLD] " .. line) end
  -- 有宿主就把日志交给宿主（它会统一加时间戳写 kr_mods_log.txt），否则自己写文件
  local host = rawget(_G, "kr_mods_log")
  if type(host) == "function" then
    host("%s", line)
    return
  end
  line = os.date("%H:%M:%S") .. "  " .. line
  buf[#buf + 1] = line
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
  if #buf >= 8 or (now - ts) > 1.0 then ts = now; flush() end
end
M.log = klog

-- ------------------------------------------------------------------ 状态与逻辑
local state = { enabled = true, level = nil, last = nil, jumps = 0 }
M.state = state

local function set_gold(st, why)
  local before = tonumber(st.player_gold) or 0
  st.player_gold = CFG.gold
  state.jumps = state.jumps + 1
  klog("金币 %d -> %d（%s）", before, CFG.gold, why)
  return true
end

function M.tick()
  if not state.enabled then return end
  local g = rawget(_G, "game")
  local st = g and g.store
  if type(st) ~= "table" then
    if state.level ~= nil then
      klog("离开关卡（本局一共跳了 %d 次）", state.jumps)
      flush()
      state.level, state.last = nil, nil
    end
    return
  end

  local lvl = tostring(st.level_name or st.level_idx or "?")
  local gold = tonumber(st.player_gold) or 0

  if lvl ~= state.level then                       -- 刚进关卡
    state.level, state.last, state.jumps = lvl, gold, 0
    klog("进入关卡 %s（起始金币 %d）", lvl, gold)
    if CFG.trigger_on_enter then set_gold(st, "进关卡") end
    state.last = tonumber(st.player_gold) or gold
    return
  end

  if CFG.pin and gold < CFG.gold then
    set_gold(st, "pin")
    state.last = CFG.gold
    return
  end

  if gold > (state.last or 0) then                  -- 拿到金币了
    set_gold(st, "拿到金币")
  end
  state.last = tonumber(st.player_gold) or gold
end
M.update = M.tick

-- ------------------------------------------------------------------ 安装
local function install()
  if state.__installed then return "already installed" end
  state.__installed = true
  -- 没有宿主（单独当 custom_script 用）时，自己包一层 love.update 兜底；
  -- 有宿主的话宿主每帧会调 M.update，不重复包。
  if rawget(_G, "kr_mods_host") ~= true then
    pcall(function()
      if type(love) ~= "table" or type(love.update) ~= "function" then return end
      if rawget(_G, "__kr_gold_love_wrapped") then return end
      rawset(_G, "__kr_gold_love_wrapped", true)
      local orig = love.update
      love.update = function(dt) pcall(M.tick); return orig(dt) end
    end)
  end
  klog("kr_gold_55555 v%s 已加载（目标金币 %d，进关卡就跳=%s）",
    M.version, CFG.gold, tostring(CFG.trigger_on_enter))
  local g = rawget(_G, "game")
  if type(g) == "table" and type(g.store) == "table" then M.tick() end
  return "installed v" .. M.version
end
M.install = install

function M.init() return install() end
-- 注意：游戏/宿主是带 self 调的（keypressed(self, key)），两种调法都认
function M.keypressed(a, b)
  local key = (a == M) and b or a
  if CFG.hotkey and tostring(key) == CFG.hotkey then
    state.enabled = not state.enabled
    klog("按 %s：金币插件 %s", tostring(CFG.hotkey), state.enabled and "开" or "关")
    return true
  end
  return false
end

pcall(install)

-- 单独当 custom_script 用时需要这个全局；有宿主时不要抢（否则宿主就收不到每帧回调了）
if rawget(_G, "kr_mods_host") ~= true then rawset(_G, "custom_script", M) end

return M
