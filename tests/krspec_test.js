// krspec_test.js — offline sandbox test for mods/kr_spec_unlimited.lua
//
//   node tests/krspec_test.js
//
// Runs the mod inside fengari (Lua) against a *fake* game: a fake level-4 ranger /
// arcane wizard / paladin tower, a fake tower_menu_power_places table and a fake
// hump.signal, then asserts the three things the mod promises:
//   1. max_level is lifted (3 and 1 both -> 99) for every purchasable power
//   2. level-indexed arrays extrapolate instead of returning nil (no tower crash)
//   3. a click on a power whose script hard-codes 1/2/3 keeps the level at the data
//      cap and buys stacking damage instead
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const HERE = __dirname;                                     // outputs/tools/_scratch
const OUT  = path.join(HERE, '..');                         // 仓库根目录
const MOD  = path.join(OUT, 'mods', 'kr_spec_unlimited.lua');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const memfs = {};
function push(luaTable, field, fn) { lua.lua_pushcfunction(L, fn); lua.lua_setfield(L, -2, to_luastring(field)); }

lua.lua_newtable(L);          // the `love` table (stays below)
lua.lua_newtable(L);
push(null, 'write', (L) => {
  memfs[to_jsstring(lua.lua_tostring(L, 1))] = to_jsstring(lua.lua_tostring(L, 2));
  return 0;
});
push(null, 'append', (L) => {
  const n = to_jsstring(lua.lua_tostring(L, 1));
  memfs[n] = (memfs[n] || '') + to_jsstring(lua.lua_tostring(L, 2));
  return 0;
});
push(null, 'read', (L) => {
  const n = to_jsstring(lua.lua_tostring(L, 1));
  if (memfs[n] !== undefined) { lua.lua_pushstring(L, to_luastring(memfs[n])); return 1; }
  lua.lua_pushnil(L);
  return 1;
});
lua.lua_setfield(L, -2, to_luastring('filesystem'));

let clock = 0;
lua.lua_newtable(L);
push(null, 'getTime', (L) => { clock += 0.02; lua.lua_pushnumber(L, clock); return 1; });
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

run(`
love.update = function(dt) LOVE_UPDATED = (LOVE_UPDATED or 0) + 1 end

-- Lua 5.3 (fengari) vs LuaJIT 5.1 shims the project already uses
loadstring = function(s, n) return load(s, n, "t", _G) end
setfenv = function(f, e) return f end
local rf = string.format
string.format = function(f, ...) local a = table.pack(...) return rf(f, table.unpack(a, 1, a.n)) end

-- fake modules: the mod looks these up with require()
-- (the real kr1 table is TNEW "array: 4, dict: 1", so mimic 4 slots *plus* a string key)
local places = {{x = 1, y = 1}, {x = 2, y = 2}, {x = 3, y = 3}, {x = 4, y = 4}, note = "kr1"}
package.loaded["data.game_gui_data"] = { tower_menu_power_places = places }

local signal = { handlers = {} }
function signal.connect(name, fn)
  signal.handlers[name] = signal.handlers[name] or {}
  table.insert(signal.handlers[name], fn)
end
function signal.emit(name, ...)
  for _, fn in ipairs(signal.handlers[name] or {}) do fn(...) end
end
package.loaded["hump.signal"] = signal

-- fake entity_db: create_entity/clone_entity deepcopy (like klua.table.deepclone, which does NOT
-- copy metatables) -- this is exactly why the mod has to guard entities at creation time
local function deepcopy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = type(v) == "table" and deepcopy(v) or v end
  return o
end
local templates = {
  ray_sunray   = { ray_y_scales = {0.35, 0.5, 0.75, 1} },
  ray_tesla    = { bounces_lvl = {2, 3} },
  tower_ranger = { tower = { type = "ranger" } },
}
package.loaded["entity_db"] = {
  entities = templates,
  create_entity = function(self, name)
    local tpl = self.entities[name]
    if not tpl then return nil end
    local e = deepcopy(tpl)
    e.template_name = name
    return e
  end,
  clone_entity = function(self, e) return deepcopy(e) end,
}

-- fake level: one of each shape the mod has to survive
local ents = {}
local ranger = {
  template_name = "tower_ranger", tower = { type = "ranger", damage_factor = 1 },
  powers = {
    poison = { level = 0, max_level = 3, price_base = 225, price_inc = 175,
               mods = {"mod_ranger_poison"},
               chances = {{0.1, 0.2, 0.3}, {0.05, 0.1, 0.15}} },
    thorn  = { level = 0, max_level = 3, price_base = 225, price_inc = 175, aura = "aura_ranger_thorn" },
  },
}
local wizard = {
  template_name = "tower_arcane_wizard", tower = { type = "arcane_wizard", damage_factor = 1 },
  powers = {
    disintegrate = { level = 0, max_level = 3, price_base = 200, price_inc = 200,
                     upper_damage = {666, 733, 800} },
    teleport     = { level = 0, max_level = 3, price_base = 200, price_inc = 150,
                     max_count = {2, 3, 4} },
  },
}
local paladin = {
  template_name = "tower_paladin", tower = { type = "paladin", damage_factor = 1 },
  powers = {
    healing = { level = 0, max_level = 3, price_base = 150, price_inc = 100 },
    shield  = { level = 0, max_level = 1, price_base = 175, price_inc = 100 },
  },
}
local plain = { template_name = "tower_archer_2", tower = { type = "archer", level = 2, damage_factor = 1 } }
local holder = { template_name = "tower_holder_grass", tower = { type = "holder" } }
-- the real store keys entities by id (number) and the value is the entity, so mirror that
ents[101] = ranger ents[102] = wizard ents[103] = paladin ents[104] = plain ents[105] = holder

game = { store = { level_name = "level01", player_gold = 9999, entities = ents } }
`, 'prelude');

lua.lua_pushstring(L, to_luastring(fs.readFileSync(MOD, 'utf8')));
lua.lua_setglobal(L, to_luastring('__MOD_SRC'));
run(`
local chunk, err = load(_G.__MOD_SRC, "@kr_spec_unlimited.lua")
assert(chunk, tostring(err))
KRSPEC = chunk()          -- the module returns M; keep it for the test
KRSPEC.tick()             -- and run one frame explicitly
`, 'kr_spec_unlimited.lua');

run(`
local M = KRSPEC
local st = game.store.entities
local function key_of(tpl) for _, e in pairs(st) do if e.template_name == tpl then return e end end end
local ranger = key_of("tower_ranger")
local wizard = key_of("tower_arcane_wizard")
local paladin = key_of("tower_paladin")
local plain = key_of("tower_archer_2")
local holder = key_of("tower_holder_grass")

local fails = 0
local function ok(cond, what)
  if cond then
    print("  PASS  " .. what)
  else
    fails = fails + 1
    print("  FAIL  " .. what)
  end
end

print("-- 1) max_level lifted for every purchasable power")
ok(ranger.powers.poison.max_level == 99, "ranger.poison.max_level 3 -> 99")
ok(ranger.powers.poison.kr_data_max == 3,  "ranger.poison remembers data cap 3")
ok(paladin.powers.shield.max_level == 99,  "paladin.shield (vanilla cap 1) -> 99")
ok(paladin.powers.shield.kr_data_max == 1, "paladin.shield remembers data cap 1")
ok(paladin.powers.healing.max_level == 99, "paladin.healing -> 99")
ok(wizard.powers.disintegrate.max_level == 99, "arcane.disintegrate -> 99")
ok(plain.tower.level == 2 and not plain.powers, "a tower without powers is untouched")
ok(holder.tower.type == "holder", "a holder is untouched")

print("-- 2) level-indexed arrays extrapolate instead of returning nil")
ok(wizard.powers.disintegrate.upper_damage[8] == 800, "upper_damage[8] == 800 (last value), not nil")
ok(wizard.powers.teleport.max_count[12] == 4,         "max_count[12] == 4, not nil")
ok(ranger.powers.poison.chances[1][9] == 0.3,         "nested chances[1][9] == 0.3, not nil")
ok(ranger.powers.poison.chances[7][2] == 0.1,         "chances[7] extrapolates the last sub-array")
ok(getmetatable(ranger.powers.poison) == nil,         "the power table itself keeps no metatable")
ok(#ranger.powers.poison.mods == 1 and ranger.powers.poison.mods[1] == "mod_ranger_poison", "normal fields survive hardening")

print("-- 3) tower menu pips table extrapolates (no nil index when max_level is big)")
local places = package.loaded["data.game_gui_data"].tower_menu_power_places
ok(#places == 4, "places length stayed 4")
ok(places[40] ~= nil and places[40].x == places[4].x, "places[40] == places[4] (pips stack), not nil")
ok(places.note == "kr1", "a string key on a mixed-key table is untouched")

print("-- 3b) level-indexed arrays on NEW entities are guarded (deepclone drops metatables)")
local db = package.loaded["entity_db"]
ok(type(db.create_entity) == "function" and rawget(_G, "__kr_spec_db_wrapped") ~= nil, "entity_db.create_entity is wrapped (once)")
local ray = db:create_entity("ray_sunray")
ok(ray.ray_y_scales[9] == 1, "a created sunray ray has ray_y_scales[9] == last entry (0.35/0.5/0.75/1)")
ok(getmetatable(ray.ray_y_scales) ~= nil, "the guard really landed on the copy")
local bolt = db:create_entity("ray_tesla")
ok(bolt.bounces_lvl[5] == 3, "a created tesla bolt has bounces_lvl[5] == last entry")
ok(getmetatable(db.entities.ray_sunray.ray_y_scales) ~= nil, "the template array is guarded too")

print("-- 4) clicks on a normal power keep the real level (default config has no keep_capped)")
local sig = package.loaded["hump.signal"]
-- exactly what the game's tower menu does: level + 1, mark changed, then emit the signal
local function click(tower, power)
  power.level = power.level + 1
  power.changed = true
  sig.emit("tower-power-upgraded", tower, power)
end
for _ = 1, 5 do click(wizard, wizard.powers.disintegrate) end
ok(wizard.powers.disintegrate.level == 5, "disintegrate keeps rising (5 clicks -> level 5)")
ok(wizard.tower.damage_factor == 1, "no phantom damage bonus while keep_capped is empty")

print("-- 4b) keep_capped powers buy +damage instead of crashing the script")
-- same as having written  keep_capped = { disintegrate = true }  into CFG before the patch
wizard.powers.disintegrate.kr_keep_capped = true
click(wizard, wizard.powers.disintegrate)   -- 6th click -> clamped + boosted
ok(wizard.powers.disintegrate.level == 3, "level clamped back to its data cap 3")
ok(wizard.powers.disintegrate.changed == true, "changed flag kept true so the tower re-applies")
ok(math.abs(wizard.tower.damage_factor - 1.15) < 1e-9, "tower damage factor 1 -> 1.15")
click(wizard, wizard.powers.disintegrate)   -- 7th click stacks
ok(math.abs(wizard.tower.damage_factor - 1.3225) < 1e-9, "clicks stack (1.15^2)")

print("-- 5) a normal power keeps its real level (the script's own formula extrapolates)")
ranger.powers.poison.level = 4
sig.emit("tower-power-upgraded", ranger, ranger.powers.poison)
ok(ranger.powers.poison.level == 4, "poison level 4 is left alone")
ok(ranger.tower.damage_factor == 1, "no phantom damage bonus on a normal power")

print("-- 6) leaving the level resets the per-level state")
game.store = nil
M.tick()
ok(M.state.level == nil, "state.level cleared when the store is gone")

print("-- 6b) the SECOND level still lifts caps (real-game bug: our own metatable was mistaken for a foreign one)")
local ranger2 = {
  template_name = "tower_ranger", tower = { type = "ranger", damage_factor = 1 },
  powers = { poison = { level = 0, max_level = 3, price_base = 225, price_inc = 175 } },
}
game.store = { level_name = "level02", player_gold = 9999, entities = { [301] = ranger2 } }
M.tick()
ok(ranger2.powers.poison.max_level == 99, "level 2: the new tower's power is lifted too")
ok(M.state.menu_ready == true, "level 2: the tower-menu guard did not bail out")
local pl2 = package.loaded["data.game_gui_data"].tower_menu_power_places
ok(pl2[30] ~= nil and pl2[30].x == pl2[4].x, "level 2: the pip table still extrapolates")

print("-- 7) the love.update fallback hook works (hot-loaded from the console)")
ok(type(love.update) == "function", "love.update is still callable after the mod installed")
love.update(0.016)
ok(LOVE_UPDATED == 1, "the original love.update still runs (our wrapper chains, it does not replace)")

print("-- 8) custom_script protocol (main.lua reads the GLOBAL, not the require result)")
ok(type(custom_script) == "table" and custom_script == KRSPEC, "the global custom_script is set")
ok(type(custom_script.init) == "function", "custom_script.init exists (main.lua calls it)")
ok(type(custom_script.update) == "function", "custom_script.update exists (called every frame)")
ok(type(custom_script.game_init) == "function", "custom_script.game_init exists (game.lua calls it)")

print("")
if fails == 0 then print("ALL PASS") else print(fails .. " FAILED") end
if fails > 0 then os.exit(1) end
`, 'assertions');

console.log('memfs writes: ' + Object.keys(memfs).join(', '));
const log = memfs['kr_spec_unlimited_log.txt'] || '';
console.log('--- mod log tail ---');
console.log(log.split('\n').slice(-14).join('\n'));
