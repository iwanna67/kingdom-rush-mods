--[[----------------------------------------------------------------------------
  KR 无限专精 (kr_spec_unlimited)  v1.0
  目标：四级（专精）防御塔的技能（tower.powers）可以一直点，不再被 3 级 / 1 级卡住。

  为什么原来只能点三次或一次（字节码 + 模板双证据）
    1) 组件默认值：all/components.lua 里 power 组件是 max_level = 3, level = 0
       （all/components.lua 反汇编:  "TSETS 34 33 466 ; power.max_level = slot34" / KSHORT 3）
       所以绝大多数四级技能最多买 3 次。
    2) 个别技能模板自己把上限压到 1，例如 kr1/barrack_towers.lua 的
       tt.powers.shield.max_level = 1（圣骑士"神圣护盾"）——所以才会出现"只能点一次"。
    3) 塔菜单（all-desktop/game_gui.lua）里只有两处判断决定"能不能点"：
         刷新按钮：if store.player_gold >= price and power.level <  power.max_level then enable
         点击处理：if power.level >= power.max_level then  什么都不做 (no-op)
       两处都用 power.max_level，所以把 max_level 抬上去 = 按钮永远可按、点击真的生效。

  这个 mod 做的事情
    A. 每帧扫描关卡里的实体，把所有"可购买技能"（power 上带 price_base/price_inc）的
       max_level 抬到 CFG.max_level（默认 99），并记下它原本的数据上限。
    B. 数组安全网：四级技能脚本大量用 pow.xxx[pow.level] 取数据（例如奥术法师的
       powers.disintegrate.upper_damage = {666,733,800}，生命之光的 cooldown 表……）。
       等级超过数组长度会取到 nil → 塔的协程报错（塔直接哑火）。
       所以给技能里所有"纯数字下标的数组"装一个 __index 元方法：越界时返回最后一个元素
       （即"等级继续涨，数值按最后一次有效值封顶"），保证不会崩。
    C. 菜单集火点：塔菜单按钮画技能等级小点时会 for i = 1, power.max_level do
       data.tower_menu_power_places[i] end，数组不够长同样会 nil 崩。
       给 data.game_gui_data.tower_menu_power_places 装同样的越界元方法。
       找不到这张表就不抬 max_level（宁可什么都不做，也不让菜单崩）。
    D. 少数"脚本里写死只有 1/2/3 级"的技能（KR1 只有奥术法师的死光 disintegrate：
       update_base_damage 用 if level == 1 / 2 / 3 分支，level 4 时 base_damage 还是 nil
       → 一发死光就把协程打崩），这类技能走"保底模式"：
       点击数照样扣钱，但等级被夹在原上限，改为给这座塔叠一个伤害倍率
       （tower.damage_factor *= CFG.boost），所以点击永远不会白费、也不会崩。

  用法
    ① 推荐（持久生效）：把本文件放到 %APPDATA%\kingdom_rush\，并在同目录 args.lua 里加一行
         ["custom_script"] = "kr_spec_unlimited";
       → 游戏启动时 main.lua 会自动 require 它并每帧调用 init/update（见 main.lua 反汇编:369/426）。
       现成的安装脚本：outputs\mods\install.ps1
    ② 热加载（游戏已经在跑，且 KRAUTO 的控制台可用）：
         Copy-Item kr_spec_unlimited.lua "$env:APPDATA\kingdom_rush\"
         # 然后往 krauto_cmd.txt 写：
         #   local m=loadstring(love.filesystem.read("kr_spec_unlimited.lua"))() return m.install()
       或者直接 outputs\mods\install.ps1 -Hot
    ③ 游戏里按 F8 可以临时开/关（日志里会写）。

  日志：%APPDATA%\kingdom_rush\kr_spec_unlimited_log.txt
  卸载：outputs\mods\install.ps1 -Uninstall（拿掉 args.lua 里那一行）

  已知取舍（写在前面免得踩坑）
    * 每点一次扣的是 price_inc（游戏原逻辑：第一级用 price_base，之后都用 price_inc），
      所以便宜技能（例如电塔连锁 187/187）点满 20 级也只要几千金。这是"一直点"必然的结果，
      想要更贵可以改 CFG.price_growth。
    * 等级超过数据表的技能，效果按"最后一个有效等级"封顶（数组安全网），伤害不会再线性涨；
      真正能线性涨的是用 pow.level 做乘加的那批（狙击、特斯拉、大贝莎、紫法石头人……）。
------------------------------------------------------------------------------]]

local M = {}
M.version = "1.3"

-- ------------------------------------------------------------------ 可调参数
local CFG = {
  max_level   = 99,      -- 告诉游戏的技能上限（按钮一直可点）
  boost       = 1.15,    -- 保底模式下，每次"多余点击"给塔叠的伤害倍率
  -- 保底模式名单（按技能名）：填进来的技能"等级不涨"，每次多余点击改成给塔叠 boost 倍伤害。
  -- 什么时候需要？脚本里把级数写死成分支（if level == 1 / 2 / 3）、光靠数组越界保护也救不回来
  -- 的技能。真机 Steam 版 KR1 逐个查过（kr1/game_scripts.lua + kr1/game_templates.lua 反汇编）：
  -- 没有任何技能有这种分支，所以默认是空的。玩 dove 那种改版源码（它给奥术法师加了
  -- powers.disintegrate.upper_damage = {666,733,800} 并且脚本按 1/2/3 分支取值）时，
  -- 把它写进来就安全了：  keep_capped = { disintegrate = true },
  keep_capped = {},
  log_file    = "kr_spec_unlimited_log.txt",
  echo        = true,    -- 同时 print 到游戏自己的日志（方便对着 krauto_log.txt 看）
  hotkey      = "f8",    -- 临时开/关
}
M.cfg = CFG

-- ------------------------------------------------------------------ 日志
local log_buf = {}
local log_ts = 0

local function flush_log()
  if #log_buf == 0 then return end
  local text = table.concat(log_buf, "\n") .. "\n"
  log_buf = {}
  local ok_fs, F = pcall(function() return love and love.filesystem end)
  if not ok_fs or type(F) ~= "table" then return end
  pcall(function()
    if F.append then
      F.append(CFG.log_file, text)
    else
      local prev = F.read(CFG.log_file) or ""
      F.write(CFG.log_file, prev .. text)
    end
  end)
end

local function klog(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  local stamp = os.date("%H:%M:%S")
  line = stamp .. "  " .. line
  log_buf[#log_buf + 1] = line
  if CFG.echo then pcall(print, "[KRSPEC] " .. line) end
  -- 每帧最多写一次盘；积到 12 行也必须落盘
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
  if #log_buf >= 12 or (now - log_ts) > 1.0 then
    log_ts = now
    flush_log()
  end
end
M.log = klog

-- 运行状态（tick 每帧更新；日志/自检会读它）
local state = {
  enabled = true,
  level = nil,
  powers = 0,
  towers = 0,
  guarded = 0,
  guard_logged = {},
  signal_hooked = false,
  menu_ready = false,
  warned_no_menu = false,
  db_wrapped = false,
}
M.state = state

-- ------------------------------------------------------------------ 数组安全网
local function is_pos_int(k)
  return type(k) == "number" and k >= 1 and k % 1 == 0
end

local function has_int_keys(t)
  for k in pairs(t) do
    if is_pos_int(k) then return true end
  end
  return false
end

local function array_last(t)
  local n = 0
  for k in pairs(t) do
    if is_pos_int(k) and k > n then n = k end
  end
  return n
end

-- 越界读返回最后一个元素（"按最后一档封顶"）。
-- 只对"数字下标"生效：字符串键的查找行为完全不变（缺键照样返回 nil），所以给混键的表
-- 装这个元方法也是安全的。元表是共享的（__index 用 self，不需要每个表一个闭包）。
local MT_EXTRAPOLATE = {
  __index = function(self, k)
    if type(k) == "number" then
      local n = array_last(self)
      if n >= 1 then return self[n] end
    end
    return nil
  end,
}

-- 塔菜单"技能等级小点"的位置表：一个位置都没有时回落到 (0,0)
local PLACE_DEFAULT = { x = 0, y = 0 }
local MT_PLACES = {
  __index = function(self, k)
    if type(k) == "number" then
      local n = array_last(self)
      if n >= 1 then return self[n] end
      return PLACE_DEFAULT
    end
    return nil
  end,
}

local function guard_array(t)
  if type(t) ~= "table" then return false end
  local mt = getmetatable(t)
  if mt == MT_EXTRAPOLATE then return true end            -- 我们自己装过的，算成功
  if mt ~= nil then return false end                      -- 别人的元表不碰
  if not has_int_keys(t) then return false end
  setmetatable(t, MT_EXTRAPOLATE)
  return true
end

local function harden(t, seen, depth)
  if type(t) ~= "table" then return 0 end
  depth = depth or 0
  if depth > 4 then return 0 end
  seen = seen or {}
  if seen[t] then return 0 end
  seen[t] = true
  local n = guard_array(t) and 1 or 0
  for _, v in pairs(t) do
    if type(v) == "table" then n = n + harden(v, seen, depth + 1) end
  end
  return n
end

-- 真机证据：把 kr1/game_scripts.lua（塔/英雄脚本都在里面）反汇编后全文件搜 ".level]"
-- （任何形如 x[pow.level] / x[b.level] / x[skill.level] 的查表读），只有这四处：
--     [991]  b.ray_y_scales[pow.level]        日光塔（sunray）射线  -> 技能 ray 有 4 级
--     [6610] this.bounces_lvl[b.level]        特斯拉弹丸的弹跳次数   -> 技能 bolt 的 max_level = 2
--     [2217]/[2270] skill.count[skill.level]  英雄技能（等级不归本 mod 管）
-- utils / script_utils / systems / level_utils 里只有英雄经验表（skill.xp_gain / hero_xp_thresholds）。
-- 也就是说：等级涨过数据表长度会读到 nil 的地方，真机 KR1 一共就这两张表（前两行）。
-- 弹丸是 E:create_entity 深拷贝出来的（klua.table.deepclone 不复制元表），所以必须挂在
-- 创建出来的实体上 —— 见下面 wrap_entity_db()。
local GUARD_FIELDS = { "ray_y_scales", "bounces_lvl" }

local function guard_entity_fields(e, why)
  if type(e) ~= "table" then return end
  for i = 1, #GUARD_FIELDS do
    local name = GUARD_FIELDS[i]
    local t = e[name]
    -- 等级表一定是 1 起（pow.level >= 1 才会被查），用 rawget(t,1) 做廉价判断
    if type(t) == "table" and getmetatable(t) == nil and rawget(t, 1) ~= nil then
      setmetatable(t, MT_EXTRAPOLATE)
      state.guarded = (state.guarded or 0) + 1
      if not (state.guard_logged or {})[name] then
        state.guard_logged = state.guard_logged or {}
        state.guard_logged[name] = true
        klog("guarded level-indexed array %s on a %s entity (%s)",
          name, tostring(e.template_name), tostring(why))
      end
    end
  end
end

-- ------------------------------------------------------------------ 世界访问
local fn_cache = {}
local function game_module(name)
  if fn_cache[name] ~= nil then return fn_cache[name] end
  local ok, m = pcall(require, name)
  if not ok or type(m) ~= "table" then m = false end
  fn_cache[name] = m
  return m
end

local function game_store()
  local g = rawget(_G, "game")
  if type(g) ~= "table" then return nil end
  local st = g.store
  if type(st) ~= "table" then return nil end
  return st, g
end

-- 找 data.game_gui_data.tower_menu_power_places：先直接 require，再扫 package.loaded / _G
local menu_places
local function find_menu_places()
  if type(menu_places) == "table" then return menu_places end
  local d = game_module("data.game_gui_data")
  if d and type(d.tower_menu_power_places) == "table" then
    menu_places = d.tower_menu_power_places
    return menu_places
  end
  local seen = {}
  local function scan(tbl, tag)
    if type(tbl) ~= "table" or seen[tbl] then return end
    seen[tbl] = true
    if type(tbl.tower_menu_power_places) == "table" then
      menu_places = tbl.tower_menu_power_places
      klog("found tower_menu_power_places inside %s", tostring(tag))
      return
    end
  end
  for k, v in pairs(package.loaded or {}) do scan(v, "package.loaded[" .. tostring(k) .. "]") end
  for k, v in pairs(_G) do scan(v, "_G." .. tostring(k)) end
  return menu_places
end

local function patch_power(p, tower_name, pname)
  if type(p) ~= "table" or p.kr_ul then return false end
  local price = tonumber(p.price_base) or tonumber(p.price_inc) or 0
  if price <= 0 then return false end
  p.kr_ul = true
  p.kr_data_max = tonumber(p.max_level) or 3
  if CFG.keep_capped[pname] then p.kr_keep_capped = true end
  local guarded = harden(p)
  p.max_level = CFG.max_level
  state.powers = state.powers + 1
  klog("tower %s: power %s capped %d -> %d (%d arrays guarded)%s",
    tostring(tower_name), tostring(pname), p.kr_data_max, CFG.max_level, guarded,
    p.kr_keep_capped and "  [kept at data cap: extra clicks buy +damage]" or "")
  return true
end

-- 点击技能后游戏会 signal.emit("tower-power-upgraded", entity, power)
-- （见 game_gui 的菜单回调：先 power.level + 1、扣钱、tower.spent 累加，最后 emit）
local function on_power_upgraded(entity, power)
  local ok, err = pcall(function()
    if type(power) ~= "table" or not power.kr_ul then return end
    -- 每次点击都在日志里留一行（这是"真的买上了"最直接的证据）
    local pname, tw = "?", type(entity) == "table" and entity.tower or nil
    if type(entity) == "table" and type(entity.powers) == "table" then
      for k, v in pairs(entity.powers) do
        if v == power then pname = k break end
      end
    end
    local lvl = tonumber(power.level) or 0
    local cap = power.kr_data_max or 0
    klog("SKILL %s %s -> lvl%d（原上限 %d%s）",
      tostring(type(tw) == "table" and tw.type or "?"), tostring(pname), lvl, cap,
      lvl > cap and "，已超过原上限" or "")
    if not power.kr_keep_capped then return end
    if (power.level or 0) <= cap then return end
    power.level = cap
    power.changed = true
    if type(tw) == "table" then
      local before = tonumber(tw.damage_factor) or 1
      tw.damage_factor = before * CFG.boost
      klog("%s: 多余点击 -> 等级夹回 %d，塔伤害倍率 x%.2f -> x%.2f",
        tostring(tw.type), cap, before, tw.damage_factor)
    end
  end)
  if not ok then klog("signal handler error: %s", tostring(err)) end
end

local function hook_signal()
  if state.signal_hooked then return true end
  local sig = game_module("hump.signal")
  if not sig or type(sig.connect) ~= "function" then return false end
  local ok, err = pcall(function() sig.connect("tower-power-upgraded", on_power_upgraded) end)
  if not ok then
    klog("could not hook tower-power-upgraded: %s", tostring(err))
    return false
  end
  state.signal_hooked = true
  klog("hooked signal tower-power-upgraded")
  return true
end

-- 弹丸/mod 都是 E:create_entity / E:clone_entity 深拷贝模板做出来的，而 klua.table.deepclone
-- 不复制元表 —— 所以对模板挂保护没用，必须在"刚创建出来"这一帧就挂上（见 GUARD_FIELDS 的说明）。
local function wrap_entity_db()
  if state.db_wrapped then return true end
  local db = game_module("entity_db")
  if not db or type(db.create_entity) ~= "function" then return false end
  -- 全局标记：mod 被加载两次（args.lua + 命令行）也只包一层
  local mark = rawget(_G, "__kr_spec_db_wrapped")
  if type(mark) ~= "table" then mark = {}; rawset(_G, "__kr_spec_db_wrapped", mark) end
  local wrappers = { "create_entity", "clone_entity" }
  for i = 1, #wrappers do
    local fname = wrappers[i]
    local orig = db[fname]
    if type(orig) == "function" and not mark[fname] then
      mark[fname] = true
      local wrapper = function(self, ...)
        local e = orig(self, ...)
        if state.enabled then guard_entity_fields(e, "E:" .. fname) end
        return e
      end
      db[fname] = wrapper
    end
  end
  state.db_wrapped = true
  -- 模板表本身也保护一遍（有代码直接读模板上的数组）
  local tpls = db.entities
  if type(tpls) == "table" then
    for name, tpl in pairs(tpls) do
      if type(tpl) == "table" then guard_entity_fields(tpl, "template " .. tostring(name)) end
    end
  end
  klog("entity_db create/clone wrapped (每颗新弹丸/新 mod 都会被挂上等级数组保护)")
  return true
end

local function guard_places(t)
  if type(t) ~= "table" then return false, "not a table" end
  local mt = getmetatable(t)
  -- ★ 真机踩过的坑（2026-10-06 用户实机日志 23:30:45）：第一关装好 MT_PLACES 之后，
  --   第二关再进来 getmetatable ~= nil 会把自己装过的元表当成"别人的" → 直接放弃抬上限。
  --   所以必须先认自己的元表。
  if mt == MT_PLACES then return true end
  if mt ~= nil then return false, "already has a foreign metatable" end
  setmetatable(t, MT_PLACES)
  return true
end

local function patch_menu()
  local places = find_menu_places()
  if type(places) ~= "table" then
    if not state.warned_no_menu then
      state.warned_no_menu = true
      klog("!! 没找到 data.game_gui_data.tower_menu_power_places：为了不让塔菜单崩，暂时不抬技能上限")
    end
    return false
  end
  if not state.menu_ready then
    local okg, why = guard_places(places)
    if not okg then
      if not state.warned_no_menu then
        state.warned_no_menu = true
        klog("!! tower_menu_power_places 加不了越界保护（%s）：为安全不抬技能上限", tostring(why))
      end
      return false
    end
    state.menu_ready = true
    klog("tower menu power places guarded (len=%d, overflow -> last entry)", array_last(places))
  end
  return true
end

local function tick()
  if not state.enabled then return end
  local st, g = game_store()
  if not st then
    flush_log()        -- 标题/地图界面也要把刚写的几行落盘（否则要等下次有日志活动才写）
    if state.level ~= nil then
      klog("left the level (patched %d powers on %d tower entities)", state.powers, state.towers)
      state.level = nil
      state.menu_ready = false
    end
    return
  end

  local lvl = tostring(st.level_name or st.level_idx or "?")
  if lvl ~= state.level then
    state.level = lvl
    state.towers = 0
    state.menu_ready = false
    menu_places = nil
    fn_cache = {}
    patch_menu()
    hook_signal()
    wrap_entity_db()
    klog("entered level %s  (mod v%s, max_level=%d)", lvl, M.version, CFG.max_level)
  end

  if not patch_menu() then return end     -- 找不到菜单表就不动手
  hook_signal()
  wrap_entity_db()

  local ents = st.entities
  if type(ents) ~= "table" then return end
  local touched = 0
  for _, e in pairs(ents) do
    if type(e) == "table" then guard_entity_fields(e, "in level") end
    local ps = type(e) == "table" and e.powers
    if type(ps) == "table" and not (type(e.tower) == "table" and e.tower.type == "holder") then
      local name = type(e.tower) == "table" and e.tower.type or e.template_name
      for pname, p in pairs(ps) do
        if type(p) == "table" and p.kr_ul then
          if p.max_level ~= CFG.max_level then      -- 被谁重置过就补回去
            p.max_level = CFG.max_level
          end
        elseif patch_power(p, name, pname) then
          touched = touched + 1
        end
      end
      if touched > 0 then
        state.towers = state.towers + 1
        touched = 0
      end
    end
  end
end
M.tick = tick

-- ------------------------------------------------------------------ 安装
local function install()
  if state.__installed then return "already installed" end
  state.__installed = true

  -- 1) 作为 custom_script 加载时，游戏自己会每帧调 update；这边再兜一层 love.update，
  --    这样"用控制台 loadstring 热加载"也能每帧生效（tick 是幂等的，跑两次没坏处）。
  --    有插件宿主（kr_mods.lua）时宿主每帧会调 M.update，就不重复包了。
  pcall(function()
    if rawget(_G, "kr_mods_host") == true then return end
    local love_t = love
    if type(love_t) ~= "table" or type(love_t.update) ~= "function" then return end
    -- 注意：函数上不能挂字段（Lua 会报 attempt to index a function value），所以用全局标记
    if rawget(_G, "__kr_spec_love_wrapped") then return end
    rawset(_G, "__kr_spec_love_wrapped", true)
    local orig = love_t.update
    local wrapper = function(dt)
      pcall(tick)
      return orig(dt)
    end
    love_t.update = wrapper
  end)

  klog("kr_spec_unlimited v%s loaded (max_level=%d, boost=%.2f)", M.version, CFG.max_level, CFG.boost)
  pcall(wrap_entity_db)
  local st = game_store()
  if st then tick() end
  return "installed v" .. M.version
end
M.install = install

-- custom_script 协议：main.lua 会 require 这个模块并调用 init/update/game_init/keypressed
-- 注意：main.lua 读的是**全局** custom_script（require 的返回值它不接）——
--   工作/asm_main.txt [403] require(main.params.custom_script)
--                    [404] if custom_script.init then custom_script.init(custom_script) end
-- 不设这个全局的话，加载到这一步会抛 "attempt to index global 'custom_script' (a nil value)"
-- 并且把 love.load 打断（实机 2026-10-06 实测）。
-- 有插件宿主时不要抢这个全局（否则宿主就收不到每帧回调，其它插件也跟着停）。
if rawget(_G, "kr_mods_host") ~= true then rawset(_G, "custom_script", M) end

function M.init() return install() end
function M.game_init() return tick() end
function M.update() return tick() end
-- 注意：游戏是带 self 调的（custom_script.keypressed(custom_script, key)，见 main.lua 反汇编 [462]），
-- 所以这里显式接 self，两种调法都认（v1.3 修：以前写 M.keypressed(key) 会被塞进 self，F8 永远不触发）。
function M.keypressed(a, b)
  local key = (a == M) and b or a
  if CFG.hotkey and tostring(key) == CFG.hotkey then
    state.enabled = not state.enabled
    klog("hotkey: mod %s", state.enabled and "ON" or "OFF (vanilla caps restored next level)")
    return true
  end
  return false
end

-- 只要这个文件被 loadstring 执行过，就自动装好
pcall(install)

return M
