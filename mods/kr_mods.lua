--[[----------------------------------------------------------------------------
  kr_mods.lua  —— 插件宿主（v1.0，2026-10-07）

  为什么需要它：游戏 main.lua 只认**一个** custom_script（main.lua 反汇编 [401]-[404]）：
      if main.params.custom_script then require(<名字>) end
      if custom_script.init then custom_script.init(custom_script) end   -- 读的是全局
  想同时挂好几个插件，就得有一个"宿主"当 custom_script，再由它去加载各个插件。

  插件协议（任何放在存档目录里的 lua 文件都可以当插件）：
      return { version = "x", init = f, update = f, keypressed = f, ... }   -- 都是可选的
    宿主做的事：
      1) 每帧调用每个插件的 update(dt)
      2) 把 keypressed / mousepressed / gamepadpressed 转发给每个插件
      3) 加载前先设 _G.kr_mods_host = true，插件看到它就知道"每帧/按键已经有人转发"，
         不需要自己再去包 love.update（避免同一帧跑两遍）

  加新插件：把 lua 文件丢进存档目录，然后在下面 PLUGINS 列表里加一行（或直接扫描目录，见 -Scan）。

  日志：%APPDATA%\kingdom_rush\kr_mods_log.txt
------------------------------------------------------------------------------]]

local M = {}
M.version = "1.0"

local CFG = {
  -- 要加载的插件（按顺序；require 的路径 = 存档目录里的 "<名字>.lua"）
  plugins = {
    "kr_spec_unlimited",   -- 四级塔专精技能可以一直点
    "kr_gold_55555",       -- 局内拿到金币就把金币跳到 55555
  },
  log_file = "kr_mods_log.txt",
  echo = true,
}
M.cfg = CFG

-- ------------------------------------------------------------------ 日志（插件也可以直接用 _G.kr_mods_log）
local buf = {}
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

local ts = 0
local function klog(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  line = os.date("%H:%M:%S") .. "  " .. line
  buf[#buf + 1] = line
  if CFG.echo then pcall(print, "[KRMODS] " .. line) end
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
  if #buf >= 12 or (now - ts) > 1.0 then ts = now; flush() end
end
M.log = klog
rawset(_G, "kr_mods_log", klog)     -- 插件可以直接用

-- ------------------------------------------------------------------ 插件加载
local plugins = {}          -- 有序：{ {name=..., mod=...}, ... }

local function load_plugin(name)
  local ok, mod = pcall(require, name)
  if not ok then
    klog("插件 %s 加载失败（跳过）：%s", tostring(name), tostring(mod))
    return false
  end
  if type(mod) ~= "table" then
    klog("插件 %s 没有返回 table（跳过）", tostring(name))
    return false
  end
  plugins[#plugins + 1] = { name = name, mod = mod }
  klog("插件已加载：%s v%s", tostring(name),
    tostring(mod.version or "?"))
  return true
end

function M.load_all()
  if M.loaded then return #plugins end          -- init() 可能被游戏再叫一次
  M.loaded = true
  -- 关键：先立旗子，插件才知道"每帧和按键有人转发"（否则它们会自己包 love.update）
  rawset(_G, "kr_mods_host", true)
  for i = 1, #CFG.plugins do load_plugin(CFG.plugins[i]) end
  klog("宿主就绪：%d/%d 个插件", #plugins, #CFG.plugins)
  flush()                                       -- 立刻落盘，别让"插件加载"这几行挂在缓冲里
  return #plugins
end
M.plugins = plugins
M.flush = flush

-- ------------------------------------------------------------------ 转发
local function each(fn_name, ...)
  for i = 1, #plugins do
    local m = plugins[i].mod
    local f = m and m[fn_name]
    if type(f) == "function" then
      local ok, err = pcall(f, m, ...)
      if not ok then klog("插件 %s 的 %s 报错：%s", tostring(plugins[i].name), fn_name, tostring(err)) end
    end
  end
end

function M.init() return M.load_all() end
function M.game_init() each("game_init") end

-- 游戏 main.lua 是**带 self** 调的：custom_script.update(custom_script, dt)
--                            custom_script.keypressed(custom_script, key, isrepeat)
-- （见 main.lua 反汇编 [426]/[462]）。这里两种调法都认，免得少传/多传 self 就失灵。
local function split1(a, b)                     -- (self, x) 或 (x)
  if a == M then return b end
  return a
end
local function split2(a, b, c)                  -- (self, x, y) 或 (x, y)
  if a == M then return b, c end
  return a, b
end

function M.update(a, b) each("update", split1(a, b)) end
function M.keypressed(a, b, c)
  local key, isrepeat = split2(a, b, c)
  return each("keypressed", key, isrepeat)
end
function M.mousepressed(a, b, c, d, e)
  local x, y, button, istouch
  if a == M then x, y, button, istouch = b, c, d, e else x, y, button, istouch = a, b, c, d end
  each("mousepressed", x, y, button, istouch)
end
function M.gamepadpressed(a, b, c)
  local joystick, button = split2(a, b, c)
  each("gamepadpressed", joystick, button)
end

klog("kr_mods v%s 开始加载", M.version)
M.load_all()

-- main.lua 读的是全局 custom_script（不是 require 的返回值）
rawset(_G, "custom_script", M)

return M
