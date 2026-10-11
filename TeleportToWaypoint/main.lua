-- Teleport to Waypoint - runtime part.
--
-- Set a waypoint on the pause map (A / left click) and you are taken there
-- instead of driving. The game's GPS is hooked at the one place the map
-- screen hands it the clicked spot (0x822A9788, called from 0x822B6988 with
-- waypoint type 0 = the player's own). The move itself is the game's own
-- player teleport (0x82481000), the one behind the mission scripts'
-- teleport("#PLAYER#", navpoint): a car you sit in and your homies come along,
-- and the world is told to load there first (0x82510520), as the scripts do.
--
-- The map only knows where you clicked, not how high the ground is there (it
-- hands the GPS a height of 0). So the player is first put high above the
-- spot and held there, and every update a ray is cast straight down from
-- just under their feet with the game's own collision probe (0x82251878, the
-- call its teleport uses to find the floor under a player) until the ground
-- there has streamed in. The first thing the ray meets from above is the
-- highest surface at that spot (a roof, a bridge, the road), and the player
-- is set down on it. Hits within a few metres of the hover point are the
-- player's own body or their homies and are ignored. A waypoint dropped onto
-- a map icon already has a real height and is used as it is.
--
-- (An earlier version faded the picture to black with the game's fade_out
-- meanwhile; the fade never lifted and blocked the menus, so no fade now.)
--
-- Single player only (and story co-op hosts, which the game counts as single
-- player); in a multiplayer session nothing happens.

local PLAYER      = 0x8309ABEC   -- pointer to the player object (0 = no game loaded)
local OBJECTS     = 0x830866C8   -- handle table, 16 bytes per entry
local UPDATE      = 0x82209E30   -- game update (the trainer hooks the same)
local MULTIPLAYER = 0x8370E9F6
local CUTSCENE_A, CUTSCENE_B = 0x8370D991, 0x8370D990
local MENU_A, MENU_B = 0x839E0DF8, 0x839E0FB0   -- a screen is up (the pause map is one)
local FRONT_END   = 0x827B04D4   -- 0 in play, -1 in the front end, 1 in the character creator

-- The GPS (route to a waypoint).
local GPS_SET            = 0x822A9788  -- (from*, to*, type, on_icon) -> true when a route was found
local MAP_SET_CALL       = 0x822B6988  -- return address of the pause map's call, after A on the map
local GPS_TYPE           = 0x8370E0EC  -- byte: type of the current route, 0 = the player's own map waypoint, 1 = a mission's
local GPS_TARGET         = 0x839E125C  -- 3 floats: where the current route ends (height 0 for plain map clicks)
local GPS_PATH           = 0x82FFE744  -- the current route (0 = none): a ring of road segments, +4 = the last one, segment+12 = its road data
local GPS_PATH_NEW       = 0x83005148  -- where the route builder puts a route first; the GPS copies it to GPS_PATH
local NEAREST_ON_ROAD    = 0x82594690  -- (road data, pos*, out*): the point on that road nearest pos, with the road's real height (the route drawer uses it)
-- (A mission's own waypoint, the blue one, is type 1 with its navpoint at
-- 0x839E1268. It is deliberately never used: only your green one counts.)

-- Teleporting.
local STREAM_AT       = 0x82510520  -- (pos*, 0, 0): load the world around a spot; the script teleport does this first
local PLAYER_TELEPORT = 0x82481000  -- (player, pos*, rows*): the script teleport("#PLAYER#", ...). Vehicle and homies come along
local HUMAN_TELEPORT  = 0x8243E6F8  -- (human, pos*, 0, nav node or -1)
local HUMAN_VELOCITY  = 0x8243E948  -- (human, velocity*)
local VEHICLE_PLACE   = 0x82535C68  -- (vehicle, pos*, rows*, 1)

-- The game's collision probe, as its own teleport uses it to find the ground under a player.
local RAYCAST      = 0x82251878  -- (query*, result*, 1, 0) -> 1 when something was hit; result+0 -> hit record, +4 = its height
local RAYCAST_FREE = 0x820C7850  -- (result*)
local RAY_RADIUS   = 0x82038850  -- 0.425: the character capsule's radius, what the game's probe passes
local RAY_FILTER   = 0x828279D0  -- the collision filter word the game's probe passes

-- HUD.
local HUD_MESSAGE = 0x82367568   -- (UTF-16 text, f1 = seconds)  the script function message

local INVULNERABLE = 0x00100000  -- flag bit at player+216 (the trainer's God Mode)

local S = {
  auto         = wml.setting("teleport_on_map_waypoint", true),
  -- Keys default to number keys: on a Mac keyboard the
  -- F-keys are brightness and volume unless Fn is held, so they are avoided.
  key          = tostring(wml.setting("teleport_key", "8")),
  close_map    = wml.setting("close_map", true),
  coords_key   = tostring(wml.setting("coords_key", "9")),
  hover        = wml.setting("hover_height", 220),
  hover_fallback = wml.setting("hover_fallback", false),
  timeout      = wml.setting("timeout_seconds", 12),
  hud          = wml.setting("hud_messages", true),
  hud_seconds  = wml.setting("hud_seconds", 3),
  debug        = wml.setting("debug", false),
}

local function log(...) wml.log(...) end
local function debug(fmt, ...) if S.debug then wml.log(string.format(fmt, ...)) end end
local function pointer_ok(v) return v >= 0x10000 and v < 0xC0000000 end
local function vec(a) return wml.read_f32(a), wml.read_f32(a + 4), wml.read_f32(a + 8) end

-- ------------------------------------------------------------ game calls
--
-- Game functions are called from inside the update hook, the way the
-- trainer does it: r1 is lowered to leave the callee stack room
-- (the collision probe alone takes 11 KB) and our own small buffers live in
-- the gap just below the hook's r1.
local SCRATCH = 0x6000
local BUF_POS, BUF_ROWS, BUF_VEL, BUF_QUERY, BUF_OUT, BUF_TEXT = 0x0F00, 0x0E80, 0x0E40, 0x0E00, 0x0D80, 0x0D00
local function buf(ctx, offset) return ctx:r(1) - offset end

local function call(ctx, fn, args, f1)
  local r1 = ctx:r(1)
  local saved = {}
  for i = 3, 10 do saved[i] = ctx:r(i) end
  local saved_f1 = ctx:f(1)
  ctx:set_r(1, r1 - SCRATCH)
  for i, v in ipairs(args) do ctx:set_r(2 + i, v) end
  if f1 then ctx:set_f(1, f1) end
  ctx:call(fn)
  local result = ctx:r(3)
  ctx:set_r(1, r1)
  for i = 3, 10 do ctx:set_r(i, saved[i]) end
  ctx:set_f(1, saved_f1)
  return result
end

local function write_pos(a, x, y, z)
  wml.write_f32(a, x); wml.write_f32(a + 4, y); wml.write_f32(a + 8, z); wml.write_f32(a + 12, 0)
end

-- ---------------------------------------------------------------- player
local function in_single_player(p)
  if p == 0 or wml.read_u32(p + 72) ~= 1 then return false end
  if wml.read_u8(MULTIPLAYER) ~= 0 then return false end
  if wml.read_u32(FRONT_END) ~= 0 then return false end
  return true
end

local function in_cutscene()
  return wml.read_u8(CUTSCENE_A) ~= 0 or wml.read_u8(CUTSCENE_B) ~= 0
end

local function in_menu()
  return wml.read_u32(MENU_A) ~= 0 or wml.read_u32(MENU_B) ~= 0
end

-- The vehicle the player sits in (the same test the keyboard controls use).
local function vehicle_object(p)
  if wml.read_u32(p + 3456) ~= 0 then return nil end
  local handle = wml.read_u32(p + 2496)
  if handle == 0 or (wml.read_u8(p + 2569) & 0x10) ~= 0 then return nil end
  local state = wml.read_u32(p + 508)
  if state == 9 or state == 12 then return nil end
  local index = handle & 0xFFFF
  if index >= 4096 then return nil end
  local object = wml.read_u32(OBJECTS + 12 + index * 16)
  if object ~= 0 and wml.read_u32(object + 68) == handle and wml.read_u32(object + 72) == 5 then return object end
  return nil
end

-- A vehicle's physics velocity: linear at +0, angular at +16 (as the co-op mod writes them).
local function vehicle_velocity(vehicle)
  if wml.read_u8(vehicle + 50300) ~= 1 then return nil end
  local body = wml.read_u32(vehicle + 244)
  if not pointer_ok(body) then return nil end
  local motion = wml.read_u32(body + 88)
  if not pointer_ok(motion) then return nil end
  return motion + 208
end

local function set_invulnerable(p, want)
  local flags = wml.read_u32(p + 216)
  if want then flags = flags | INVULNERABLE else flags = flags & ~INVULNERABLE & 0xFFFFFFFF end
  wml.write_u32(p + 216, flags)
  wml.write_u32(p + 212, wml.read_u32(p + 212) | 1)  -- the game's dirty flag
end

-- Fall protection while hanging in the air and for the landing: the
-- invulnerability bit is set and the fall start (+404) kept at the player, so
-- no fall damage, stumble or ragdoll. Put back as it was afterwards.
local shield_was, shield_until = nil, 0
local tick = 0
local function shield_on(p)
  if shield_was == nil then shield_was = (wml.read_u32(p + 216) & INVULNERABLE) ~= 0 end
  set_invulnerable(p, true)
end
local function shield_off(p)
  if shield_was ~= nil then
    if p ~= 0 then set_invulnerable(p, shield_was) end
    shield_was = nil
  end
  shield_until = 0
end

-- --------------------------------------------------------------- HUD text
local hud_queue = {}
local function hud(text) if S.hud then hud_queue[#hud_queue + 1] = text end end
local function flush_hud(ctx)
  if #hud_queue == 0 then return end
  local text = table.remove(hud_queue, 1)
  local a = buf(ctx, BUF_TEXT)
  local n = math.min(#text, 200)
  for i = 1, n do wml.write_u16(a + (i - 1) * 2, string.byte(text, i)) end
  wml.write_u16(a + n * 2, 0)
  call(ctx, HUD_MESSAGE, { a }, S.hud_seconds)
  debug("hud: %s", text)
end

-- ------------------------------------------------------------- moving
local function teleport(ctx, p, x, y, z, stream)
  local pos, rows = buf(ctx, BUF_POS), buf(ctx, BUF_ROWS)
  write_pos(pos, x, y, z)
  for i = 0, 32, 4 do wml.write_u32(rows + i, wml.read_u32(p + 32 + i)) end  -- keep the facing
  if stream then call(ctx, STREAM_AT, { pos, 0, 0 }) end
  call(ctx, PLAYER_TELEPORT, { p, pos, rows })
  wml.write_f32(p + 404, x); wml.write_f32(p + 408, y); wml.write_f32(p + 412, z)
end

-- Keeps the player (or their car) at a spot in the air, the way the
-- trainer's No Clip does: position set and velocity zeroed every update.
local function hold(ctx, p, x, y, z)
  local pos = buf(ctx, BUF_POS)
  write_pos(pos, x, y, z)
  local vehicle = vehicle_object(p)
  if vehicle then
    call(ctx, VEHICLE_PLACE, { vehicle, pos, vehicle + 32, 1 })
    local v = vehicle_velocity(vehicle)
    if v then
      for i = 0, 8, 4 do wml.write_f32(v + i, 0); wml.write_f32(v + 16 + i, 0) end
    end
  else
    local node = wml.read_u32(p + 392)
    if tick % 30 == 0 or node == 0xFFFFFFFF then node = 0xFFFFFFFF end
    call(ctx, HUMAN_TELEPORT, { p, pos, 0, node })
    local vel = buf(ctx, BUF_VEL)
    write_pos(vel, 0, 0, 0)
    call(ctx, HUMAN_VELOCITY, { p, vel })
  end
  wml.write_f32(p + 404, x); wml.write_f32(p + 408, y); wml.write_f32(p + 412, z)
end

-- Height of whatever is under (x, z), from `top` down to `bottom`, with the
-- game's own probe (same query as its teleport builds, only longer). nil
-- when nothing is hit, which is the case until the ground there is loaded.
local function ground_height(ctx, x, z, top, bottom)
  local q, out = buf(ctx, BUF_QUERY), buf(ctx, BUF_OUT)
  for i = 0, 92, 4 do wml.write_u32(q + i, 0) end
  wml.write_f32(q, x);      wml.write_f32(q + 4, top);     wml.write_f32(q + 8, z)
  wml.write_f32(q + 12, x); wml.write_f32(q + 16, bottom); wml.write_f32(q + 20, z)
  wml.write_f32(q + 24, wml.read_f32(RAY_RADIUS))
  wml.write_u32(q + 76, wml.read_u32(RAY_FILTER))
  wml.write_u32(out, 0); wml.write_u32(out + 4, 0); wml.write_u32(out + 8, 0x80000000)
  local hit = (call(ctx, RAYCAST, { q, out, 1, 0 }) & 0xFF) == 1
  local y, info, solid, frac
  if hit then
    local record = wml.read_u32(out)
    if pointer_ok(record) then
      y = wml.read_f32(record + 4)
      frac = wml.read_f32(record + 36)
      -- A real surface names a material (+44), a shape (+48) and an object
      -- (+52). Invisible volumes in the sky answered with all of them unset
      -- (0xFF / 0xFFFFFFFF), 40-60 m above the roads.
      local material, shape, object = wml.read_u32(record + 44), wml.read_u32(record + 48), wml.read_u32(record + 52)
      solid = object ~= 0xFFFFFFFF or shape ~= 0xFFFFFFFF
      info = string.format("frac %.3f material %02X shape %08X object %08X%s",
        wml.read_f32(record + 36), material, shape, object, solid and "" or " (no body: a volume)")
    end
  end
  call(ctx, RAYCAST_FREE, { out })
  return y, info, solid, frac
end

-- ------------------------------------------------------------ the job
--
-- request: a spot to go to, picked up by the next update.
-- job:     the move in progress (hanging in the air until the ground shows).
local request, job = nil, nil
local close_frames, closing = 0, false
local show_coords, coords_tick = false, 0
local rate = 50  -- game updates per second, measured
local updates, second = 0, os.time()

local function cancel(ctx, p, why)
  if job then debug("cancelled: %s", why) end
  job = nil
  if p ~= 0 then shield_until = tick + 60 else shield_off(0) end
end

local function finish(ctx, p, y, how)
  local vehicle = vehicle_object(p)
  local lift = vehicle and 0.6 or 0.1
  teleport(ctx, p, job.x, y + lift, job.z, false)
  log(string.format("Teleported to the waypoint at %.1f %.1f %.1f (%s, %s, %d updates)",
    job.x, y + lift, job.z, how, vehicle and "in a vehicle" or "on foot", job.updates))
  hud("Teleported to the waypoint")
  job = nil
  shield_until = tick + 90  -- through the landing
end

-- The road point the route ends on: the GPS route's last segment is the road
-- nearest the waypoint, and the road carries its real height. Needs no
-- streaming, so this is the normal, instant way.
-- Heap pointers on the 360 can sit anywhere from low addresses up into the
-- 0xC0000000 range, so only 0 and tiny values are refused here.
local function heap_ok(v) return v >= 0x10000 and v < 0xFFFF0000 end
local function route_end(ctx, target)
  local path = wml.read_u32(GPS_PATH_NEW)
  if not heap_ok(path) then path = wml.read_u32(GPS_PATH) end
  local last = heap_ok(path) and wml.read_u32(path + 4) or 0
  local data = heap_ok(last) and wml.read_u32(last + 12) or 0
  if not heap_ok(data) then
    debug("route not readable: path %08X / %08X last %08X data %08X", wml.read_u32(GPS_PATH_NEW), wml.read_u32(GPS_PATH), last, data)
    return nil
  end
  local out = buf(ctx, BUF_VEL)
  write_pos(out, 0, 0, 0)
  call(ctx, NEAREST_ON_ROAD, { data, target or GPS_TARGET, out })
  local x, y, z = vec(out)
  if y ~= y or y < -100 or y > 600 then
    debug("route end point unusable: %.1f %.1f %.1f", x, y, z)
    return nil
  end
  return x, y, z
end

-- Second step after landing on the road: the GPS road nodes are coarse (the
-- nearest one can be 100 m from the click, at a placeholder height), so once
-- the world around has loaded, the clicked column itself is probed from
-- above and the player moved onto the highest surface there.
local settle = nil

-- Puts the player on the road point and starts the second step.
local function land_on_road(ctx, p, rx, ry, rz, cx, cz, off, how)
  local vehicle = vehicle_object(p)
  local lift = vehicle and 0.6 or 0.2
  teleport(ctx, p, rx, ry + lift, rz, true)
  log(string.format("Teleported to the route's road point %.1f %.1f %.1f (%.1f m from the click, %s, %s)",
    rx, ry + lift, rz, off, how, vehicle and "in a vehicle" or "on foot"))
  job = nil
  shield_until = tick + 90
  settle = { x = cx, z = cz, est = ry, updates = 0 }
end

local function settle_step(ctx, p)
  settle.updates = settle.updates + 1
  local px, py, pz = vec(p + 20)
  local dx, dz = settle.x - px, settle.z - pz
  local flat = math.sqrt(dx * dx + dz * dz)
  local vehicle = vehicle_object(p)
  local lift = vehicle and 1.0 or 0.2
  local done
  done = function(y, how)
    if vehicle then
      -- The game's player teleport looks for a free spot for a car and may
      -- shift it; for the exact spot the car is placed the way the script
      -- function teleport_vehicle does it: settle every wheel, move body and
      -- physics, then the after-move call, with the velocity zeroed.
      local pos = buf(ctx, BUF_POS)
      write_pos(pos, settle.x, y + lift, settle.z)
      local wheels = math.min(call(ctx, 0x82534AE8, { vehicle }) & 0xFFFF, 16)
      for i = 0, wheels - 1 do
        local wheel = call(ctx, 0x82534EC8, { vehicle, i })
        if wheel ~= 0 then call(ctx, 0x825353C0, { vehicle, wheel }, 0.0) end
      end
      call(ctx, VEHICLE_PLACE, { vehicle, pos, vehicle + 32, 1 })
      call(ctx, 0x8253BA90, { vehicle })
      local v = vehicle_velocity(vehicle)
      if v then for i = 0, 8, 4 do wml.write_f32(v + i, 0); wml.write_f32(v + 16 + i, 0) end end
      wml.write_f32(p + 404, settle.x); wml.write_f32(p + 408, y + lift); wml.write_f32(p + 412, settle.z)
    else
      teleport(ctx, p, settle.x, y + lift, settle.z, false)
    end
    log(string.format("Moved onto the waypoint at %.1f %.1f %.1f (%s, %d updates)", settle.x, y + lift, settle.z, how, settle.updates))
    hud("Teleported to the waypoint")
    settle = nil
    shield_until = tick + 90
  end
  if flat < 20 then
    -- Too close for the probe (it would meet the player's own proxy); the
    -- ground here is the ground there. Let the player settle first.
    if settle.updates >= 5 then done(py, "same height as the road point") end
    return
  end
  local top = settle.top or (math.max(settle.est, py) + 80)
  local bottom = settle.est - 40
  if top < bottom + 5 then
    if settle.volume_y then
      -- Only volumes were met: the lowest one is the best guess left.
      done(settle.volume_y, "nothing solid, lowest volume hit")
      return
    end
    log(string.format("Nothing over the click at %.1f %.1f; staying on the road point", settle.x, settle.z))
    hud("Teleported near the waypoint")
    settle = nil
    return
  end
  local y, info, solid, frac = ground_height(ctx, settle.x, settle.z, top, bottom)
  if y then
    debug("settle: probe from %.1f hit %.1f (%s)", top, y, info or "?")
    local dy = y - py
    local dist = math.sqrt(flat * flat + dy * dy)
    local started_inside = (frac or 1) <= 0.001
    if dist < 20 then
      debug("settle: hit %.1f is %.1f m from the player, their own proxy; ignored", y, dist)
    elseif not solid then
      -- A volume, not a surface. A hit at fraction 0 means the ray started
      -- inside it: step down through it; otherwise start just under its top.
      settle.volume_y = math.min(settle.volume_y or y, y)
      settle.top = started_inside and (top - 2) or (y - 0.5)
    else
      done(y, string.format("highest surface found from %.1f", top))
      return
    end
  end
  if settle.updates > 4 * rate then
    log(string.format("No surface found over the click at %.1f %.1f; staying on the road point", settle.x, settle.z))
    hud("Teleported near the waypoint")
    settle = nil
  end
end

local function start(ctx, p)
  local r = request
  request = nil
  local _, py = vec(p + 20)
  local rx, ry, rz
  if r.road then
    -- Read in the hook, the moment the route existed.
    rx, ry, rz = r.road[1], r.road[2], r.road[3]
  else
    rx, ry, rz = route_end(ctx)
  end
  if rx then
    local dx, dz = rx - r.x, rz - r.z
    local off = math.sqrt(dx * dx + dz * dz)
    if off < 200 then
      shield_on(p)
      land_on_road(ctx, p, rx, ry, rz, r.x, r.z, off, "at once")
      return
    end
    log(string.format("Not moving: the nearest road to %.1f %.1f is %.0f m away (off the road network)", r.x, r.z, off))
    hud("Teleport: that spot is too far from any road, staying put")
    return
  else
    debug("route end not readable")
  end
  if not S.hover_fallback then
    log(string.format("Not moving: the route to %.1f %.1f gave no road point", r.x, r.z))
    hud("Teleport: couldn't read the route, staying put")
    return
  end
  job = { x = r.x, z = r.z, y_hint = r.known and r.y or nil, updates = 0, started = tick }
  -- High enough to be above anything in Stilwater, so the first hit on the
  -- way down is the highest surface there. An icon's own height is trusted
  -- but still checked from above, in case a roof sits over it.
  job.hover = math.max(S.hover, py + 40, (job.y_hint or 0) + 40)
  shield_on(p)
  teleport(ctx, p, job.x, job.hover, job.z, true)
  debug("going to %.1f %.1f (height %s), hovering at %.1f", job.x, job.z, job.y_hint and string.format("%.1f", job.y_hint) or "unknown", job.hover)
end

local function step(ctx, p)
  if in_menu() then
    -- The map is still open (or another screen): keep the player where they
    -- are and wait; nothing streams while the game is paused.
    hold(ctx, p, job.x, job.hover, job.z)
    return
  end
  job.updates = job.updates + 1
  -- The route may become readable a little after the click: ask again.
  local rx, ry, rz = route_end(ctx)
  if rx then
    local dx, dz = rx - job.x, rz - job.z
    local off = math.sqrt(dx * dx + dz * dz)
    if off < 200 then
      land_on_road(ctx, p, rx, ry, rz, job.x, job.z, off, string.format("after %d updates", job.updates))
      return
    end
  end
  -- Something about 15 m across travels with the player (a ray started
  -- anywhere near them reported a hit 15 m away, at every spot in the city),
  -- so the ray starts 30 m under the hover point, and a hit in the first few
  -- metres after that is still treated as not the world.
  local top = job.hover - 30
  local ground = ground_height(ctx, job.x, job.z, top, -300)
  if ground then debug("probe from %.1f hit %.1f", top, ground) end
  if ground and ground > job.hover - 36 then
    debug("probe hit %.1f, too close to the hover point %.1f; ignored", ground, job.hover)
    ground = nil
  end
  if ground then
    finish(ctx, p, ground, "ground found")
    return
  end
  if job.updates > S.timeout * rate then
    if job.y_hint then
      finish(ctx, p, job.y_hint, "no ground found, used the icon's height")
    else
      log(string.format("No ground found under %.1f %.1f after %d updates; letting the player drop", job.x, job.z, job.updates))
      hud("Teleport: no ground found, dropping")
      job = nil
      shield_until = tick + 20 * rate
    end
    return
  end
  hold(ctx, p, job.x, job.hover, job.z)
end

-- The key: go to your own (green) map waypoint. A mission's blue one is
-- left alone, so the game can't send you somewhere you didn't choose.
local function request_from_gps()
  if wml.read_u32(GPS_PATH) == 0 then hud("No waypoint set"); return end
  local kind = wml.read_u8(GPS_TYPE)
  if kind ~= 0 then
    hud("Only your own map waypoint is used, not a mission's")
    debug("key: current route is a mission's (type %d), ignored", kind)
    return
  end
  local x, y, z = vec(GPS_TARGET)
  request = { x = x, y = y, z = z, known = (y ~= 0) }
  debug("key: your waypoint at %.1f %.1f %.1f", x, y, z)
end

-- ----------------------------------------------------------------- hooks

-- The pause map setting the player's waypoint.
if S.auto then
  wml.hook(GPS_SET, function(ctx)
    local from_map = ctx:lr() == MAP_SET_CALL and (ctx:r(5) & 0xFF) == 0
    local x, y, z, on_icon
    if from_map then
      local to = ctx:r(4)
      x, y, z = vec(to)
      on_icon = (ctx:r(6) & 0xFF) ~= 0
    end
    ctx:call_original()
    if not from_map then return end
    local routed = (ctx:r(3) & 0xFF) ~= 0
    if wml.read_u8(MULTIPLAYER) ~= 0 then
      debug("map waypoint in multiplayer, ignored")
      return
    end
    if not routed then
      debug("map waypoint at %.1f %.1f refused by the GPS (no route), ignored", x, z)
      return
    end
    -- The route exists right now (it is gone again by the next update), so
    -- take its end point here: the road the GPS leads to, with real height.
    -- The clicked spot is still in r4's memory.
    local rx, ry, rz = route_end(ctx, ctx:r(4))
    request = { x = x, y = y, z = z, known = on_icon, road = rx and { rx, ry, rz } or nil }
    if S.close_map then closing, close_frames = true, 0 end
    debug("map waypoint at %.1f %.1f %.1f%s; road point %s", x, y, z, on_icon and " (on an icon)" or "",
      rx and string.format("%.1f %.1f %.1f", rx, ry, rz) or "not readable")
  end)
end

-- Closing the map: Backspace is B for the keyboard controls, and B leaves
-- the map (Start, tried first, did not close it from the map tab). One press
-- was not always taken, so B is tapped (4 frames down, 4 up) until no screen
-- is up any more, for at most 3 seconds.
local CLOSE_KEY = 8  -- VK_BACK
local SCREEN_C, SCREEN_D = 0x82FFE434, 0x82FFE43C  -- the other two screen slots the keyboard layer watches
local function any_screen_up()
  return wml.read_u32(MENU_A) ~= 0 or wml.read_u32(MENU_B) ~= 0 or wml.read_u32(SCREEN_C) ~= 0 or wml.read_u32(SCREEN_D) ~= 0
end
wml.on_frame(function()
  if not closing then return end
  if not any_screen_up() or close_frames > 180 then
    wml.force_key(CLOSE_KEY, false)
    closing = false
    if close_frames > 180 then debug("map did not close after %d frames", close_frames) end
    return
  end
  wml.force_key(CLOSE_KEY, (close_frames % 8) < 4)
  close_frames = close_frames + 1
end)

wml.hook(UPDATE, function(ctx)
  ctx:call_original()
  tick = tick + 1
  updates = updates + 1
  local now = os.time()
  if now ~= second then
    if updates > 10 then rate = updates end
    updates, second = 0, now
  end

  local p = wml.read_u32(PLAYER)
  if not in_single_player(p) then
    if job or request then request = nil; cancel(ctx, 0, "no single-player game") end
    settle = nil
    shield_was = nil
    return
  end
  flush_hud(ctx)
  if S.key ~= "" and wml.key_pressed(S.key) and not in_cutscene() then request_from_gps() end

  -- Position readout: coords.dll (in this folder) draws it in the corner
  -- every frame; here the position is only written to the log once a
  -- second while it is on, so a spot that misbehaves can be named exactly.
  if S.coords_key ~= "" and wml.key_pressed(S.coords_key) then
    show_coords = not show_coords
    coords_tick = 0
  end
  if show_coords and not in_menu() and tick - coords_tick >= rate then
    coords_tick = tick
    local x, y, z = vec(p + 20)
    log(string.format("Position %.1f  %.1f  %.1f%s", x, y, z, vehicle_object(p) and "  (in a vehicle)" or ""))
  end

  if request then
    if in_cutscene() then
      request = nil
      debug("request dropped: cutscene")
    else
      if job then cancel(ctx, p, "new waypoint") end
      settle = nil
      start(ctx, p)
    end
  end
  if job then
    if in_cutscene() then cancel(ctx, p, "cutscene") else step(ctx, p) end
  end
  if settle and not job then
    if in_cutscene() then settle = nil elseif not in_menu() then settle_step(ctx, p) end
  end

  -- Fall protection after a move, then put the flag back.
  if shield_was ~= nil and not job then
    if tick < shield_until then
      local x, y, z = vec(p + 20)
      wml.write_f32(p + 404, x); wml.write_f32(p + 408, y); wml.write_f32(p + 412, z)
    else
      shield_off(p)
    end
  end
end)

log(string.format("Running: map waypoints %s, key %s, close map %s, hover %.0f m, timeout %.0f s",
  S.auto and "teleport" or "ignored", S.key ~= "" and S.key or "none", S.close_map and "yes" or "no",
  S.hover, S.timeout))
