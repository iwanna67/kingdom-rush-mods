// krmods_test.js — 沙箱测试：插件宿主 kr_mods.lua + 金币插件 kr_gold_55555.lua
//
//   node tests/krmods_test.js
//
// 用 fengari 起一个假游戏，把 outputs/mods 下的宿主和插件按真实的 require 顺序加载起来，断言：
//   1. 宿主成为全局 custom_script，两个插件都被它加载
//   2. 金币：进关卡就跳到 55555；花掉不会被瞬间补回；再拿到金币又跳回 55555
//   3. F9 能开关金币插件（证明 keypressed 转发可用）
//   4. 每帧转发可用：专精插件（第一个插件）通过宿主的 update 也在正常抬上限
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const HERE = __dirname;
const OUT  = path.join(HERE, '..');                 // 仓库根目录
const MODS = path.join(OUT, 'mods');
const HOST = path.join(MODS, 'kr_mods.lua');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const memfs = {};
const pushc = (field, fn) => { lua.lua_pushcfunction(L, fn); lua.lua_setfield(L, -2, to_luastring(field)); };

lua.lua_newtable(L);                                  // love
lua.lua_newtable(L);                                  // love.filesystem
pushc('write', (L) => { memfs[to_jsstring(lua.lua_tostring(L, 1))] = to_jsstring(lua.lua_tostring(L, 2)); return 0; });
pushc('append', (L) => {
  const n = to_jsstring(lua.lua_tostring(L, 1));
  memfs[n] = (memfs[n] || '') + to_jsstring(lua.lua_tostring(L, 2));
  return 0;
});
pushc('read', (L) => {
  const n = to_jsstring(lua.lua_tostring(L, 1));
  if (memfs[n] !== undefined) { lua.lua_pushstring(L, to_luastring(memfs[n])); return 1; }
  lua.lua_pushnil(L);
  return 1;
});
lua.lua_setfield(L, -2, to_luastring('filesystem'));
let clock = 0;
lua.lua_newtable(L);                                  // love.timer
pushc('getTime', (L) => { clock += 0.02; lua.lua_pushnumber(L, clock); return 1; });
lua.lua_setfield(L, -2, to_luastring('timer'));
lua.lua_setglobal(L, to_luastring('love'));

function run(src, name) {
  if (lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring(name)) !== lua.LUA_OK) {
    throw new Error('compile ' + name + ': ' + to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    const e = to_jsstring(lua.lua_tostring(L, -1));
    lua.lua_pop(L, 1);
    throw new Error(name + ': ' + e);
  }
}

// 让 require("<名字>") 去 mods/<名字>.lua 读文件（和游戏里 require 存档目录的插件一致）
lua.lua_pushcfunction(L, (L) => {
  const name = to_jsstring(lua.lua_tostring(L, 1));
  const file = path.join(MODS, name + '.lua');
  if (fs.existsSync(file)) { lua.lua_pushstring(L, to_luastring(fs.readFileSync(file, 'utf8'))); return 1; }
  lua.lua_pushnil(L);
  return 1;
});
lua.lua_setglobal(L, to_luastring('__read_mod_file'));

// 给断言脚本看"写出去的文件"
lua.lua_pushcfunction(L, (L) => {
  const n = to_jsstring(lua.lua_tostring(L, 1));
  if (memfs[n] !== undefined) { lua.lua_pushstring(L, to_luastring(memfs[n])); return 1; }
  lua.lua_pushnil(L);
  return 1;
});
lua.lua_setglobal(L, to_luastring('__memfs_read'));

lua.lua_pushstring(L, to_luastring(fs.readFileSync(HOST, 'utf8')));
lua.lua_setglobal(L, to_luastring('__HOST_SRC'));

run(`
loadstring = function(s, n) return load(s, n, "t", _G) end
setfenv = function(f, e) return f end
local rf = string.format
string.format = function(f, ...) local a = table.pack(...) return rf(f, table.unpack(a, 1, a.n)) end

-- 假 require：和游戏一样按模块名找 <名字>.lua
local cache = {}
package = { loaded = cache }
function require(n)
  if cache[n] ~= nil then return cache[n] end
  local src = __read_mod_file(n)
  if not src then error("module '" .. n .. "' not found") end
  local f = assert(load(src, "@" .. n .. ".lua", "t", _G))
  local m = f()
  if m == nil then m = true end
  cache[n] = m
  return m
end

-- 假游戏世界：塔菜单小点表 / 信号 / entity_db / 关卡
package.loaded["data.game_gui_data"] = { tower_menu_power_places = {{x=1,y=1},{x=2,y=2},{x=3,y=3}, note="kr1"} }
local signal = { handlers = {} }
function signal.connect(n, f) signal.handlers[n] = signal.handlers[n] or {}; table.insert(signal.handlers[n], f) end
function signal.emit(n, ...) for _, f in ipairs(signal.handlers[n] or {}) do f(...) end end
package.loaded["hump.signal"] = signal
package.loaded["entity_db"] = {
  entities = {},
  create_entity = function(self, name) return { template_name = name } end,
  clone_entity  = function(self, e) local o = {} for k, v in pairs(e) do o[k] = v end return o end,
}

local tower = {
  template_name = "tower_ranger", tower = { type = "ranger", damage_factor = 1 },
  powers = { thorn = { level = 0, max_level = 3, price_base = 225, price_inc = 175 } },
}
game = { store = { level_name = "level01", player_gold = 800, entities = { [1] = tower } } }

local chunk, err = load(__HOST_SRC, "@kr_mods.lua")
assert(chunk, tostring(err))
HOST = chunk()          -- 宿主（加载它 = 连带加载两个插件，和游戏里 custom_script 一样）
`, 'prelude');

run(`
local fails = 0
local function ok(cond, what)
  if cond then print("  PASS  " .. what) else fails = fails + 1 print("  FAIL  " .. what) end
end

print("-- 1) 宿主与插件加载")
ok(type(HOST) == "table" and HOST.version == "1.0", "宿主 kr_mods v1.0 加载")
ok(custom_script == HOST, "全局 custom_script 指向宿主（main.lua 读的就是它）")
ok(#HOST.plugins == 2, "两个插件都在宿主列表里")
ok(package.loaded["kr_spec_unlimited"] ~= nil, "插件 kr_spec_unlimited 已被 require")
local gold = package.loaded["kr_gold_55555"]
ok(type(gold) == "table" and gold.version == "1.0", "插件 kr_gold_55555 v1.0 已加载")
ok(rawget(_G, "kr_mods_host") == true, "宿主立了 kr_mods_host 旗子（插件不会重复包 love.update）")

print("-- 2) 金币插件：进关卡就跳到 55555")
HOST.update(0.016)
ok(game.store.player_gold == 55555, "进关卡后金币 800 -> 55555")

print("-- 3) 花钱有效，不会被瞬间补回")
game.store.player_gold = 40000
HOST.update(0.016)
ok(game.store.player_gold == 40000, "花掉 15555 之后不会自动回满（pin=false）")

print("-- 4) 再拿到金币（比如打怪 +50）又跳回 55555")
game.store.player_gold = 40050
HOST.update(0.016)
ok(game.store.player_gold == 55555, "拿到金币 -> 55555")
HOST.update(0.016)
ok(game.store.player_gold == 55555 and gold.state.jumps == 2, "下一帧不会反复跳（本局累计 2 次）")

print("-- 5) F9 开关（证明 keypressed 转发可用）")
HOST.keypressed("f9")
ok(gold.state.enabled == false, "F9 关掉金币插件")
game.store.player_gold = 100
HOST.update(0.016)
ok(game.store.player_gold == 100, "关掉后金币不再被改")
HOST.keypressed("f9")
ok(gold.state.enabled == true, "F9 再打开")

print("-- 6) 换关卡会重置（每局独立）")
game.store = { level_name = "level02", player_gold = 700, entities = {} }
HOST.update(0.016)
ok(game.store.player_gold == 55555, "第二关进关也是 55555")

print("-- 7) 每帧转发可用：专精插件通过宿主在正常抬上限")
local wizard = {
  template_name = "tower_arcane_wizard", tower = { type = "arcane_wizard", damage_factor = 1 },
  powers = { disintegrate = { level = 0, max_level = 3, price_base = 200, price_inc = 200 } },
}
game.store.entities = { [11] = wizard }
HOST.update(0.016)
ok(wizard.powers.disintegrate.max_level == 99, "宿主 update -> 专精插件 tick -> max_level 3->99")
ok(package.loaded["data.game_gui_data"].tower_menu_power_places[9] ~= nil, "小点表越界外推仍然生效")

print("-- 8) 宿主日志")
local log = __memfs_read("kr_mods_log.txt") or ""
ok(log:find("插件已加载：kr_gold_55555") ~= nil, "kr_mods_log.txt 里有插件加载记录")

print("")
if fails == 0 then print("ALL PASS") else print(fails .. " FAILED") end
if fails > 0 then os.exit(1) end
`, 'assertions');

const log = memfs['kr_mods_log.txt'] || '';
console.log('--- kr_mods_log.txt（前 12 行）---');
console.log(log.split('\n').slice(0, 12).join('\n'));
