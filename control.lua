-- WePlay: Shock Lance
-- Primary fire (normal shoot) is an instant beam, damaged by the gun's own line trigger.
-- Alt fire (custom hotkey) launches a slow plasma orb, handled here.
-- A beam that passes through an orb detonates it: the shock combo.
-- Everything runs on energy from the armor's batteries, not ammo.

local CATEGORY = "wp-shock-lance"
local GUN = "wp-shock-lance"
local CHARGE = "wp-shock-charge"   -- hidden one-shot ammo the script keeps loaded

local IDLE_WATTS = 100000          -- 100 kW while the Shock Lance is the selected gun
local SHOT_JOULES = 1500000        -- 1.5 MJ per beam or orb
local COMBO_JOULES = 5000000       -- 5 MJ per shock combo
local IDLE_INTERVAL = 10           -- ticks between idle drains and charge checks

local BOLT_MIN_RANGE = 40       -- tiles; bolts always reach at least as far as orbs fly
local BOLT_SPEED = 1.6          -- tiles per tick (40 tiles in 25 ticks)
local BOLT_LENGTH = 3           -- visible streak length in tiles
local BOLT_HIT_RADIUS = 0.6
local BOLT_DAMAGE = 45
local MUZZLE_HEIGHT = 0.75      -- barrel height above the character's feet, in tiles (measured in game)
local MUZZLE_FORWARD = 0.95     -- barrel tip distance in front of the character

local ORB_SPEED = 0.3          -- tiles per tick
local ORB_COOLDOWN = 40        -- ticks between orbs per player
local ORB_DAMAGE = 60
local ORB_BLAST_RADIUS = 2.5

local COMBO_DAMAGE = 320

-- Map settings (changeable mid-game). Orb diameter in tiles, orb travel distance in tiles,
-- combo blast radius in tiles. Contact and catch radii scale with the orb's size.
local function setting(name) return settings.global[name].value end
local function orb_diameter() return setting("wp-shock-lance-orb-diameter") end
local function orb_range() return setting("wp-shock-lance-orb-range") end
local function combo_radius() return setting("wp-shock-lance-combo-radius") end
local ORB_SPRITE_DIAMETER = 2   -- tiles at scale 1

local PURPLE = { r = 0.62, g = 0.3, b = 1, a = 1 }
local WHITE_HOT = { r = 0.95, g = 0.85, b = 1, a = 1 }

local function init_storage()
  storage.orbs = storage.orbs or {}
  storage.combos = storage.combos or {}
  storage.craters = storage.craters or {}
  storage.bolts = storage.bolts or {}
  storage.next_id = storage.next_id or 1
  storage.cooldowns = storage.cooldowns or {}
  storage.capacitors = storage.capacitors or {}
end

script.on_init(init_storage)
script.on_configuration_changed(init_storage)

-- Helpers ---------------------------------------------------------------------

-- Research bonus times the damage multiplier map setting. Applies to bolts, orbs and combos.
local function damage_bonus(force)
  local multiplier = settings.global["wp-shock-lance-damage-multiplier"].value
  return (1 + force.get_ammo_damage_modifier(CATEGORY)) * multiplier
end

local function enemy_forces_of(force)
  local list = {}
  for _, other in pairs(game.forces) do
    if force.is_enemy(other) then table.insert(list, other) end
  end
  return list
end

-- Damage hostile entities in a radius, with linear falloff down to 40% at the edge.
-- With friendly fire on, friendly characters and buildings caught in the blast are hurt too.
local function blast(surface, position, radius, amount, force, cause)
  local valid_cause = cause and cause.valid and cause or nil
  local function hurt(entity)
    if entity.valid and entity.is_entity_with_health and entity.destructible and entity.health then
      local dx, dy = entity.position.x - position.x, entity.position.y - position.y
      local falloff = 1 - 0.6 * math.min(1, math.sqrt(dx * dx + dy * dy) / radius)
      entity.damage(amount * falloff, force, "electric", nil, valid_cause)
    end
  end

  local enemies = enemy_forces_of(force)
  if #enemies > 0 then
    for _, entity in pairs(surface.find_entities_filtered({ position = position, radius = radius, force = enemies })) do
      hurt(entity)
    end
  end
  -- Friendly fire (map setting): everything that isn't an enemy or neutral is hit too —
  -- the shooter, teammates, allies, and their buildings and vehicles. Enemies were already
  -- hit above; neutral trees and rocks are handled by clear_terrain.
  if settings.global["wp-shock-lance-friendly-fire"].value then
    local friendly = {}
    for _, other in pairs(game.forces) do
      if not force.is_enemy(other) and other.name ~= "neutral" then table.insert(friendly, other) end
    end
    if #friendly > 0 then
      for _, entity in pairs(surface.find_entities_filtered({ position = position, radius = radius, force = friendly })) do
        hurt(entity)
      end
    end
  end
end

-- Shock combos blow away trees, rocks and ground decoratives (grass, pebbles) in the
-- blast radius (map setting). Trees and rocks are destroyed, not mined: no items drop,
-- and trees leave stumps behind.
local function clear_terrain(surface, position, radius, force, cause)
  if not settings.global["wp-shock-lance-clear-terrain"].value then return end
  local valid_cause = cause and cause.valid and cause or nil
  local obstacles = surface.find_entities_filtered({
    position = position, radius = radius, type = { "tree", "simple-entity" }, force = "neutral",
  })
  for _, entity in pairs(obstacles) do
    if entity.valid then entity.die(force, valid_cause) end
  end
  -- Decoratives are cleared row by row so the cleared patch is round.
  for dy = math.floor(-radius), math.ceil(radius) do
    local half = math.sqrt(math.max(0, radius * radius - dy * dy))
    if half > 0 then
      surface.destroy_decoratives({
        area = { { position.x - half, position.y + dy }, { position.x + half, position.y + dy + 1 } },
      })
    end
  end
end

-- A square search area around a point. Area searches test each entity's collision box,
-- so big targets like spawners are hit anywhere on their footprint, not just near the centre.
local function box_around(point, half)
  return { { point.x - half, point.y - half }, { point.x + half, point.y + half } }
end

-- Distance from point p to the segment a-b.
local function distance_to_segment(p, a, b)
  local abx, aby = b.x - a.x, b.y - a.y
  local len2 = abx * abx + aby * aby
  local t = 0
  if len2 > 0 then
    t = math.max(0, math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
  end
  local cx, cy = a.x + abx * t - p.x, a.y + aby * t - p.y
  return math.sqrt(cx * cx + cy * cy)
end

-- Suit energy ----------------------------------------------------------------
-- The lance has its own internal capacitor (per character) that fills from the suit's
-- spare generator output, so suits running on generators with no batteries still work.
-- Shots spend the capacitor first, then the armor's batteries.

local CAPACITOR_MAX = 10000000   -- 10 MJ: one shot plus one combo, with some wiggle room

local function capacitor(character)
  local entry = storage.capacitors[character.unit_number]
  if not entry then
    entry = { character = character, energy = 0 }
    storage.capacitors[character.unit_number] = entry
  end
  return entry
end

local function suit_energy(character)
  if not character.valid then return 0 end
  local grid = character.grid
  local batteries = grid and grid.available_in_batteries or 0
  local stored = storage.capacitors[character.unit_number]
  return batteries + (stored and stored.energy or 0)
end

-- Takes energy from the capacitor, then the batteries. Returns false (taking nothing) if short.
local function drain_suit(character, joules)
  if suit_energy(character) < joules then return false end
  local entry = capacitor(character)
  local from_cap = math.min(entry.energy, joules)
  entry.energy = entry.energy - from_cap
  joules = joules - from_cap
  if joules > 0 and character.grid then
    for _, equipment in pairs(character.grid.equipment) do
      if joules <= 0 then break end
      if equipment.type == "battery-equipment" then
        local take = math.min(equipment.energy, joules)
        equipment.energy = equipment.energy - take
        joules = joules - take
      end
    end
  end
  return true
end

local GENERATOR_TYPES = { ["generator-equipment"] = true, ["solar-panel-equipment"] = true, ["battery-equipment"] = true }

-- Estimates the suit's spare generator output over `ticks` ticks: energy that would otherwise
-- be wasted. Returns 0 while batteries are still charging (the game is already storing the
-- spare there) or while any other equipment is refilling its buffer (it gets power first).
local function spare_generator_energy(character, ticks)
  local grid = character.grid
  if not grid then return 0 end
  if grid.battery_capacity > 0 and grid.available_in_batteries < grid.battery_capacity * 0.99 then return 0 end

  local reserved = 0   -- steady draw from always-on equipment, J/tick
  for _, equipment in pairs(grid.equipment) do
    if not GENERATOR_TYPES[equipment.type] then
      if equipment.max_energy > 0 and equipment.energy < equipment.max_energy * 0.98 then return 0 end
      local ok, use = pcall(function() return equipment.prototype.energy_consumption end)
      if ok and use then reserved = reserved + use end
    end
  end

  local ok, generated = pcall(function() return grid.get_generator_energy() end)
  generated = ok and generated or 0
  local surface = character.surface
  local daylight = (1 - surface.darkness) * surface.solar_power_multiplier
  generated = generated + grid.max_solar_energy * daylight

  return math.max(0, generated - reserved) * ticks
end

local function lance_is_selected(character)
  local gun = character.get_inventory(defines.inventory.character_guns)[character.selected_gun_index]
  return gun and gun.valid_for_read and gun.name == GUN
end

-- Keep one hidden charge in each Shock Lance's ammo slot while the suit can afford a shot,
-- and take it away when it can't, so the gun simply won't fire on low power.
-- The charge's rounds (out of 100) mirror the charge level, so the ammo slot's bar is a charge meter.
local function charge_percent(character)
  local grid = character.grid
  local capacity = CAPACITOR_MAX + (grid and grid.battery_capacity or 0)
  return math.max(1, math.min(100, math.ceil(suit_energy(character) / capacity * 100)))
end

local function update_charges(character)
  local guns = character.get_inventory(defines.inventory.character_guns)
  local ammo = character.get_inventory(defines.inventory.character_ammo)
  if not (guns and ammo) then return end
  local can_fire = suit_energy(character) >= SHOT_JOULES
  local percent = can_fire and charge_percent(character)
  for i = 1, #guns do
    local slot = ammo[i]
    local has_charge = slot.valid_for_read and slot.name == CHARGE
    local is_lance = guns[i].valid_for_read and guns[i].name == GUN
    if is_lance and can_fire then
      if not slot.valid_for_read then slot.set_stack({ name = CHARGE, count = 1 }) end
      if slot.valid_for_read and slot.name == CHARGE and slot.ammo ~= percent then slot.ammo = percent end
    elseif has_charge then
      slot.clear()
    end
  end
end

local function destroy_orb(id)
  local orb = storage.orbs[id]
  if not orb then return end
  for _, part in pairs(orb.parts or {}) do
    if part.valid then part.destroy() end
  end
  if orb.light and orb.light.valid then orb.light.destroy() end
  storage.orbs[id] = nil
end

-- Orb impact and combo -------------------------------------------------------

local function orb_impact(id)
  local orb = storage.orbs[id]
  local surface = game.get_surface(orb.surface_index)
  if surface and orb.force.valid then
    blast(surface, orb.position, ORB_BLAST_RADIUS, ORB_DAMAGE * damage_bonus(orb.force), orb.force, orb.cause)
    -- No explosion: the orb just winks out with a small puff of lavender sparks and a flash.
    local scale = orb.scale or 1
    rendering.draw_light({
      sprite = "utility/light_small", target = { x = orb.position.x, y = orb.position.y - MUZZLE_HEIGHT },
      surface = surface, scale = 2 * scale, intensity = 0.9, color = PURPLE, time_to_live = 8,
    })
    for _ = 1, math.floor(14 * math.max(1, scale)) do
      local angle = math.random() * 2 * math.pi
      local speed = (0.03 + math.random() * 0.07) * scale
      surface.create_particle({
        name = "wp-shock-spark", position = orb.position,
        movement = { math.cos(angle) * speed, math.sin(angle) * speed },
        height = MUZZLE_HEIGHT, vertical_speed = math.random() * 0.06 - 0.01, frame_speed = 1,
      })
    end
  end
  destroy_orb(id)
end

-- The combo explosion, a little supernova: a white-hot core with light spikes, a lens-flare
-- streak, a wispy expanding shell, a thin tilted equator ring, sparkly haze, lavender sparks,
-- and a scorched crater that fades away after a while. Animated in on_tick.
local COMBO_TICKS = 45
local CRATER_LIFE = 60 * 60       -- ticks before the crater starts fading (60 s)
local CRATER_FADE = 5 * 60        -- ticks to fade out
local CRATER_BLOOM = 150          -- ticks for the big bloom to fade (2.5 s)
local CRATER_GLOW = 8 * 60        -- ticks for the quieter crack glow to cool
local SHELL_SPRITE_RADIUS = 3.2   -- ring radius of the shell/equator sprites at scale 1
local HAZE_SPRITE_RADIUS = 2
local VOLUME_SPRITE_RADIUS = 2
local CRATER_SCALE = 1.3

local function ease_out(x)
  x = math.max(0, math.min(1, x))
  return 1 - (1 - x) ^ 3
end

-- 1 until `from`, then linear down to 0 at `to`.
local function fade_between(t, from, to)
  return math.max(0, math.min(1, 1 - (t - from) / (to - from)))
end

-- Sprites fade by tint; tints are premultiplied by alpha.
local function set_alpha(object, alpha)
  if object and object.valid then
    pcall(function() object.color = { r = alpha, g = alpha, b = alpha, a = alpha } end)
  end
end

local function set_scale(object, x, y)
  if object and object.valid then
    object.x_scale = x
    object.y_scale = y or x
  end
end

local function spark(surface, position, angle, speed, lift)
  surface.create_particle({
    name = "wp-shock-spark",
    position = position,
    movement = { math.cos(angle) * speed, math.sin(angle) * speed },
    height = 0.3 + math.random() * 0.4,
    vertical_speed = lift,
    frame_speed = 1,
  })
end

local function draw_fx(sprite, surface, position, layer)
  return rendering.draw_sprite({
    sprite = sprite, target = position, surface = surface, render_layer = layer or "air-object",
    x_scale = 0.01, y_scale = 0.01,
  })
end

local function draw_crater(surface, position, size)
  local orientation = math.random()
  local scale = CRATER_SCALE * size
  local function decal(sprite)
    local ok, object = pcall(rendering.draw_sprite, {
      sprite = sprite, target = position, surface = surface, render_layer = "decals",
      orientation = orientation, x_scale = scale, y_scale = scale,
    })
    if ok then return object end
    return rendering.draw_sprite({
      sprite = sprite, target = position, surface = surface, render_layer = "lower-object",
      orientation = orientation, x_scale = scale, y_scale = scale,
    })
  end
  table.insert(storage.craters, {
    crater = decal("wp-shock-crater"),
    glow = decal("wp-shock-crater-glow"),
    bloom = decal("wp-shock-crater-bloom"),
    -- The bloom sprite doubles as a real light, so the crater lights up the ground at night.
    light = rendering.draw_light({
      sprite = "wp-shock-crater-bloom", target = position, surface = surface,
      orientation = orientation, scale = scale, intensity = 1,
    }),
    born = game.tick,
  })
end

local function shock_combo(id, force, cause)
  local orb = storage.orbs[id]
  local surface = game.get_surface(orb.surface_index)
  local position = orb.position
  destroy_orb(id)
  if not surface then return end

  if helpers.is_valid_sound_path("wp-shock-combo") then
    surface.play_sound({ path = "wp-shock-combo", position = position })
  end
  local radius = combo_radius()
  local size = radius / 7          -- the visuals were designed around a 7-tile blast
  blast(surface, position, radius, COMBO_DAMAGE * damage_bonus(force), force, cause)
  clear_terrain(surface, position, radius, force, cause)
  draw_crater(surface, position, size)

  -- Draw order: volume, haze, shell, equator, core, flare (later draws sit on top).
  table.insert(storage.combos, {
    age = 0,
    surface_index = surface.index,
    position = position,
    radius = radius,
    size = size,
    volume = draw_fx("wp-supernova-volume", surface, position),
    haze = draw_fx("wp-supernova-haze", surface, position),
    shell = draw_fx("wp-supernova-shell", surface, position),
    equator = draw_fx("wp-supernova-equator", surface, position),
    core = draw_fx("wp-supernova-core", surface, position),
    flare = draw_fx("wp-supernova-flare", surface, position),
    light = rendering.draw_light({
      sprite = "utility/light_medium", target = position, surface = surface,
      scale = 10 * size, intensity = 1, color = PURPLE,
    }),
  })

  -- Opening burst of sparks and twinkles flying outward.
  for _ = 1, math.floor(50 * math.max(1, size)) do
    spark(surface, position, math.random() * 2 * math.pi, (0.08 + math.random() * 0.22) * size, 0.02 + math.random() * 0.08)
  end
end

local function animate_combo(combo)
  local t = combo.age
  local COMBO_RADIUS = combo.radius
  local size = combo.size

  -- Core: snaps open, then slowly shrinks and fades while spinning.
  local core_scale = (0.4 + ease_out(t / 6)) * (1 - 0.3 * math.max(0, t - 6) / (COMBO_TICKS - 6))
  set_scale(combo.core, core_scale * size)
  set_alpha(combo.core, fade_between(t, 8, 40))
  if combo.core.valid then combo.core.orientation = t * 0.002 end

  -- Lens flare: a fast horizontal streak.
  set_scale(combo.flare, 1.4 * size * ease_out(t / 4), size)
  set_alpha(combo.flare, fade_between(t, 4, 26))

  -- Solid, saturated purple volume under the glow.
  set_scale(combo.volume, (COMBO_RADIUS - 0.8) * ease_out(t / 11) / VOLUME_SPRITE_RADIUS)
  set_alpha(combo.volume, 0.9 * fade_between(t, 14, COMBO_TICKS))

  -- Haze fills the blast.
  set_scale(combo.haze, (COMBO_RADIUS - 0.5) * ease_out(t / 12) / HAZE_SPRITE_RADIUS)
  set_alpha(combo.haze, 0.8 * fade_between(t, 8, COMBO_TICKS))

  -- Wispy shell expands to the damage radius.
  set_scale(combo.shell, COMBO_RADIUS * ease_out(t / 16) / SHELL_SPRITE_RADIUS)
  set_alpha(combo.shell, fade_between(t, 12, COMBO_TICKS))
  if combo.shell.valid then combo.shell.orientation = t * 0.001 end

  -- Thin tilted equator ring, a bit wider than the shell.
  local equator = COMBO_RADIUS * 1.1 * ease_out(t / 18) / SHELL_SPRITE_RADIUS
  set_scale(combo.equator, equator, equator * 0.32)
  set_alpha(combo.equator, fade_between(t, 10, 40))

  if combo.light.valid then combo.light.intensity = fade_between(t, 6, COMBO_TICKS) end

  -- Fill the middle with drifting sparks while the haze is expanding.
  local surface = game.get_surface(combo.surface_index)
  if surface and t < 14 then
    local reach = (COMBO_RADIUS - 0.5) * ease_out(t / 12) * 0.85
    for _ = 1, math.min(30, math.floor(6 * math.max(1, size * size))) do
      local angle = math.random() * 2 * math.pi
      local distance = math.sqrt(math.random()) * reach
      local at = { x = combo.position.x + math.cos(angle) * distance, y = combo.position.y + math.sin(angle) * distance }
      spark(surface, at, angle, 0.01 + math.random() * 0.04, 0.01 + math.random() * 0.04)
    end
  end
end

local function destroy_combo(combo)
  for _, key in pairs({ "volume", "haze", "shell", "equator", "core", "flare", "light" }) do
    if combo[key] and combo[key].valid then combo[key].destroy() end
  end
end

-- Craters: the glow cools over 8 s; the crater fades out after 60 s.
local function update_craters()
  for i = #storage.craters, 1, -1 do
    local entry = storage.craters[i]
    local age = game.tick - entry.born
    -- The big bloom flashes and fades fast, settling into the quieter crack glow,
    -- which holds, then cools off faster toward the end.
    local bloom = math.max(0, 1 - age / CRATER_BLOOM) ^ 1.5
    local heat = math.max(0, 1 - (age / CRATER_GLOW) ^ 2)
    if entry.bloom and entry.bloom.valid then
      if age >= CRATER_BLOOM then entry.bloom.destroy() else set_alpha(entry.bloom, bloom) end
    end
    if entry.glow and entry.glow.valid then
      if age >= CRATER_GLOW then entry.glow.destroy() else set_alpha(entry.glow, heat) end
    end
    if entry.light and entry.light.valid then
      if age >= CRATER_GLOW then entry.light.destroy() else entry.light.intensity = math.max(bloom, 0.3 * heat) end
    end
    if age >= CRATER_LIFE + CRATER_FADE or not (entry.crater and entry.crater.valid) then
      if entry.crater and entry.crater.valid then entry.crater.destroy() end
      for _, key in pairs({ "glow", "bloom", "light" }) do
        if entry[key] and entry[key].valid then entry[key].destroy() end
      end
      table.remove(storage.craters, i)
    elseif age > CRATER_LIFE then
      set_alpha(entry.crater, 1 - (age - CRATER_LIFE) / CRATER_FADE)
    end
  end
end

-- Primary fire: the bolt -----------------------------------------------------
-- A short glowing bolt flies from the barrel, hits the first enemy it touches, and sets
-- off a shock combo if it catches an orb on the way. Positions are on the ground; the
-- bolt and the orb are drawn MUZZLE_HEIGHT above it, at gun height.

local function lifted(position)
  return { x = position.x, y = position.y - MUZZLE_HEIGHT }
end

local function muzzle(origin, dx, dy)
  return { x = origin.x + dx * MUZZLE_FORWARD, y = origin.y + dy * MUZZLE_FORWARD }
end

script.on_event(defines.events.on_script_trigger_effect, function(event)
  if event.effect_id ~= "wp-shock-beam" then return end
  local shooter = event.source_entity
  if not (shooter and shooter.valid) then return end
  local surface = game.get_surface(event.surface_index)
  if not surface then return end

  local origin = shooter.position
  local aim = event.target_position
  if not aim and shooter.shooting_state then aim = shooter.shooting_state.position end
  if not aim then return end
  local dx, dy = aim.x - origin.x, aim.y - origin.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.01 then return end
  dx, dy = dx / len, dy / len

  if shooter.type == "character" then
    drain_suit(shooter, SHOT_JOULES)
    update_charges(shooter)
  end

  local start = muzzle(origin, dx, dy)
  local function line(color, width)
    return rendering.draw_line({
      color = color, width = width, from = lifted(start), to = lifted(start), surface = surface,
    })
  end
  table.insert(storage.bolts, {
    surface_index = surface.index,
    start = start,
    position = start,
    direction = { x = dx, y = dy },
    travelled = 0,
    range = math.max(BOLT_MIN_RANGE, orb_range()),
    force = shooter.force,
    cause = shooter,
    enemies = enemy_forces_of(shooter.force),
    glow = line(PURPLE, 9),
    core = line(WHITE_HOT, 3),
    light = rendering.draw_light({
      sprite = "utility/light_small", target = lifted(start), surface = surface,
      scale = 1.5, intensity = 0.8, color = PURPLE,
    }),
  })
  -- Muzzle flash.
  rendering.draw_light({
    sprite = "utility/light_small", target = lifted(start), surface = surface,
    scale = 2, intensity = 1, color = PURPLE, time_to_live = 4,
  })
end)

local function destroy_bolt(bolt)
  for _, key in pairs({ "glow", "core", "light" }) do
    if bolt[key] and bolt[key].valid then bolt[key].destroy() end
  end
end

local function bolt_burst(surface, position)
  rendering.draw_light({
    sprite = "utility/light_small", target = lifted(position), surface = surface,
    scale = 2.5, intensity = 1, color = PURPLE, time_to_live = 6,
  })
  for _ = 1, 6 do
    surface.create_particle({
      name = "wp-shock-spark", position = position,
      movement = { (math.random() - 0.5) * 0.2, (math.random() - 0.5) * 0.2 },
      height = MUZZLE_HEIGHT * 0.6, vertical_speed = 0.03 + math.random() * 0.04, frame_speed = 1,
    })
  end
end

-- Moves one bolt a tick. Returns true when the bolt is spent.
local function step_bolt(bolt)
  local surface = game.get_surface(bolt.surface_index)
  if not surface or not bolt.force.valid then return true end

  local step = math.min(BOLT_SPEED, bolt.range - bolt.travelled)
  local from = bolt.position
  local to = { x = from.x + bolt.direction.x * step, y = from.y + bolt.direction.y * step }

  -- Orb in the way? Shock combo (5 MJ more), or the orb just pops if the suit can't pay.
  for id, orb in pairs(storage.orbs) do
    if orb.surface_index == bolt.surface_index
      and distance_to_segment(orb.position, from, to) <= orb.catch_radius then
      local cause = bolt.cause.valid and bolt.cause or nil
      if cause and cause.type == "character" and drain_suit(cause, COMBO_JOULES) then
        update_charges(cause)
        shock_combo(id, bolt.force, cause)
      elseif not cause or cause.type ~= "character" then
        shock_combo(id, bolt.force, cause)
      else
        orb_impact(id)
      end
      return true
    end
  end

  -- Enemy in the way? Sample along this tick's path.
  if #bolt.enemies > 0 then
    local samples = math.max(1, math.ceil(step / 0.5))
    for i = 1, samples do
      local f = i / samples
      local point = { x = from.x + (to.x - from.x) * f, y = from.y + (to.y - from.y) * f }
      local hits = surface.find_entities_filtered({ area = box_around(point, BOLT_HIT_RADIUS), force = bolt.enemies })
      for _, entity in pairs(hits) do
        if entity.valid and entity.is_entity_with_health and entity.destructible and entity.health then
          local cause = bolt.cause.valid and bolt.cause or nil
          entity.damage(BOLT_DAMAGE * damage_bonus(bolt.force), bolt.force, "electric", nil, cause)
          bolt_burst(surface, point)
          return true
        end
      end
    end
  end

  bolt.position = to
  bolt.travelled = bolt.travelled + step
  if bolt.travelled >= bolt.range then return true end

  -- Draw the bolt: a short streak behind the head, never reaching back past the barrel.
  local tail_length = math.min(BOLT_LENGTH, bolt.travelled)
  local tail = { x = to.x - bolt.direction.x * tail_length, y = to.y - bolt.direction.y * tail_length }
  local head, back = lifted(to), lifted(tail)
  for _, key in pairs({ "glow", "core" }) do
    if bolt[key].valid then
      bolt[key].from = back
      bolt[key].to = head
    end
  end
  if bolt.light.valid then bolt.light.target = head end
  return false
end

-- Alt fire: the orb ---------------------------------------------------------

script.on_event("wp-shock-lance-alt-fire", function(event)
  local player = game.get_player(event.player_index)
  if not player or player.controller_type ~= defines.controllers.character then return end
  local character = player.character
  if not (character and character.valid) or character.vehicle then return end

  if not lance_is_selected(character) then return end

  local ready_at = storage.cooldowns[player.index] or 0
  if event.tick < ready_at then return end

  local target = event.cursor_position
  local origin = character.position
  local dx, dy = target.x - origin.x, target.y - origin.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.01 then return end
  dx, dy = dx / len, dy / len

  if not drain_suit(character, SHOT_JOULES) then
    player.create_local_flying_text({ text = { "wp-shock-lance.no-energy" }, create_at_cursor = true })
    return
  end
  update_charges(character)
  storage.cooldowns[player.index] = event.tick + ORB_COOLDOWN

  local surface = character.surface
  local position = muzzle(origin, dx, dy)
  local id = storage.next_id
  storage.next_id = id + 1
  local diameter = orb_diameter()
  local scale = diameter / ORB_SPRITE_DIAMETER
  local function part(sprite)
    return rendering.draw_sprite({
      sprite = sprite, target = lifted(position), surface = surface, render_layer = "air-object",
      x_scale = scale, y_scale = scale,
    })
  end
  storage.orbs[id] = {
    surface_index = surface.index,
    position = position,
    velocity = { x = dx * ORB_SPEED, y = dy * ORB_SPEED },
    life = math.ceil(orb_range() / ORB_SPEED),
    scale = scale,
    hit_radius = 0.45 * diameter,     -- touching an enemy
    catch_radius = 0.75 * diameter,   -- how close a bolt must pass to set off a combo
    force = character.force,
    cause = character,
    enemies = enemy_forces_of(character.force),
    parts = {
      part("wp-shock-orb-glass-back"),
      rendering.draw_animation({
        animation = "wp-shock-orb-lightning", target = lifted(position), surface = surface, render_layer = "air-object",
        animation_offset = math.random(0, 15), x_scale = scale, y_scale = scale,
      }),
      part("wp-shock-orb-core"),
      part("wp-shock-orb-glass-front"),
    },
    light = rendering.draw_light({
      sprite = "utility/light_medium", target = lifted(position), surface = surface,
      scale = 1.5 * scale, intensity = 0.9, color = PURPLE,
    }),
  }

  if helpers.is_valid_sound_path("wp-shock-orb-fire") then
    surface.play_sound({ path = "wp-shock-orb-fire", position = position })
  end
end)

-- Tick: move bolts and orbs, animate combos ----------------------------------

script.on_event(defines.events.on_tick, function(event)
  if #storage.craters > 0 then update_craters() end   -- every tick so the bloom fades smoothly

  if #storage.bolts > 0 then
    for i = #storage.bolts, 1, -1 do
      local bolt = storage.bolts[i]
      if step_bolt(bolt) then
        destroy_bolt(bolt)
        table.remove(storage.bolts, i)
      end
    end
  end

  if next(storage.orbs) then
    for id, orb in pairs(storage.orbs) do
      local surface = game.get_surface(orb.surface_index)
      if not surface or not orb.force.valid then
        destroy_orb(id)
      else
        orb.position = { x = orb.position.x + orb.velocity.x, y = orb.position.y + orb.velocity.y }
        orb.life = orb.life - 1
        local pulse = 1 + 0.12 * math.sin(event.tick * 0.5)
        local at = lifted(orb.position)
        for index, part in pairs(orb.parts) do
          if part.valid then
            part.target = at
            if index == 3 then   -- the core electrode pulses
              part.x_scale = pulse * orb.scale
              part.y_scale = pulse * orb.scale
            end
          end
        end
        if orb.light.valid then orb.light.target = lifted(orb.position) end

        local hit = #orb.enemies > 0 and surface.find_entities_filtered({
          area = box_around(orb.position, orb.hit_radius), force = orb.enemies, limit = 1,
        })[1]
        if hit then
          orb_impact(id)
        elseif orb.life <= 0 then
          destroy_orb(id)
        end
      end
    end
  end

  if #storage.combos > 0 then
    for i = #storage.combos, 1, -1 do
      local combo = storage.combos[i]
      combo.age = combo.age + 1
      if combo.age > COMBO_TICKS or not combo.core.valid then
        destroy_combo(combo)
        table.remove(storage.combos, i)
      else
        animate_combo(combo)
      end
    end
  end
end)

-- Idle drain and charge upkeep ---------------------------------------------

script.on_nth_tick(IDLE_INTERVAL, function()
  for _, player in pairs(game.connected_players) do
    local character = player.character
    if character and character.valid then
      if lance_is_selected(character) then
        -- Spare generator output fills the capacitor; the 100 kW idle draw comes out of it,
        -- and anything the generators can't cover comes from the batteries.
        local net = spare_generator_energy(character, IDLE_INTERVAL) - IDLE_WATTS * IDLE_INTERVAL / 60
        if net >= 0 then
          local entry = capacitor(character)
          entry.energy = math.min(CAPACITOR_MAX, entry.energy + net)
        else
          drain_suit(character, math.min(-net, suit_energy(character)))
        end
      end
      update_charges(character)
    end
  end
  -- Forget capacitors of characters that no longer exist.
  for unit_number, entry in pairs(storage.capacitors) do
    if not entry.character.valid then storage.capacitors[unit_number] = nil end
  end
end)

-- The hidden charge never leaves the gun's ammo slot.
local function purge_charges(player)
  local inventory = player.get_main_inventory()
  if inventory then
    local count = inventory.get_item_count(CHARGE)
    if count > 0 then inventory.remove({ name = CHARGE, count = count }) end
  end
  local cursor = player.cursor_stack
  if cursor and cursor.valid_for_read and cursor.name == CHARGE then cursor.clear() end
end

script.on_event(defines.events.on_player_main_inventory_changed, function(event)
  local player = game.get_player(event.player_index)
  if player then purge_charges(player) end
end)

script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
  local player = game.get_player(event.player_index)
  if player then purge_charges(player) end
end)

script.on_event(defines.events.on_player_gun_inventory_changed, function(event)
  local player = game.get_player(event.player_index)
  if player and player.character then update_charges(player.character) end
end)

-- Don't leave charges in the corpse.
script.on_event(defines.events.on_pre_player_died, function(event)
  local player = game.get_player(event.player_index)
  local ammo = player and player.character and player.character.get_inventory(defines.inventory.character_ammo)
  if not ammo then return end
  for i = 1, #ammo do
    if ammo[i].valid_for_read and ammo[i].name == CHARGE then ammo[i].clear() end
  end
end)
