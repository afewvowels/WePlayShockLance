local GFX = "__WePlayShockLance__/graphics/"
local CATEGORY = "wp-shock-lance"
local RANGE = 40

local SFX = "__WePlayShockLance__/sound/"

local prototypes = {
  {
    type = "ammo-category",
    name = CATEGORY,
    icon = GFX .. "icons/shock-lance.png",
    icon_size = 64,
  },

  -- The rifle. Primary fire is the normal shoot button.
  {
    type = "gun",
    name = "wp-shock-lance",
    icon = GFX .. "icons/shock-lance.png",
    icon_size = 64,
    subgroup = "gun",
    order = "d[wp-shock-lance]",
    stack_size = 5,
    attack_parameters = {
      type = "projectile",
      ammo_categories = { CATEGORY },
      cooldown = 50,
      movement_slow_down_factor = 0.3,
      range = RANGE,
      sound = { filename = SFX .. "shock-lance-beam.ogg", volume = 0.7 },
    },
  },

  -- Hidden "charge". The script keeps one in the Shock Lance's ammo slot whenever the
  -- suit can afford a shot, and takes it out when it can't. Its rounds are set to the
  -- suit's charge percentage, so the ammo slot's magazine bar works as a charge meter.
  -- Players never craft or hold it.
  {
    type = "ammo",
    name = "wp-shock-charge",
    icon = GFX .. "icons/shock-charge.png",
    icon_size = 64,
    hidden = true,
    flags = { "not-stackable" },
    subgroup = "ammo",
    order = "z[wp-shock-charge]",
    stack_size = 1,
    magazine_size = 100,
    ammo_category = CATEGORY,
    ammo_type = {
      target_type = "direction",
      clamp_position = true,
      action = {
        -- Tell control.lua a shot fired: it charges the suit and launches the bolt, which
        -- handles its own damage and combos as it flies.
        {
          type = "direct",
          action_delivery = {
            type = "instant",
            target_effects = {
              { type = "script", effect_id = "wp-shock-beam" },
            },
          },
        },
      },
    },
  },

  -- The plasma orb: a little plasma-ball toy in layers (glass back, lightning, core, glass front).
  { type = "sprite", name = "wp-shock-orb-glass-back", filename = GFX .. "entity/orb-glass-back.png", size = 128, scale = 0.5 },
  {
    type = "animation",
    name = "wp-shock-orb-lightning",
    filename = GFX .. "entity/orb-lightning.png",
    size = 128,
    scale = 0.5,
    frame_count = 16,
    line_length = 4,
    animation_speed = 0.5,
    blend_mode = "additive",
  },
  { type = "sprite", name = "wp-shock-orb-core", filename = GFX .. "entity/orb-core.png", size = 128, scale = 0.5, blend_mode = "additive" },
  { type = "sprite", name = "wp-shock-orb-glass-front", filename = GFX .. "entity/orb-glass-front.png", size = 128, scale = 0.5, blend_mode = "additive" },

  {
    type = "custom-input",
    name = "wp-shock-lance-alt-fire",
    key_sequence = "mouse-button-2",
    alternative_key_sequence = "G",
    consuming = "none",
    action = "lua",
  },

  {
    type = "recipe",
    name = "wp-shock-lance",
    enabled = false,
    energy_required = 10,
    ingredients = {
      { type = "item", name = "steel-plate", amount = 10 },
      { type = "item", name = "advanced-circuit", amount = 10 },
      { type = "item", name = "battery", amount = 10 },
      { type = "item", name = "plastic-bar", amount = 5 },
    },
    results = { { type = "item", name = "wp-shock-lance", amount = 1 } },
  },

  {
    type = "technology",
    name = "wp-shock-lance",
    icon = GFX .. "icons/shock-lance-tech.png",
    icon_size = 256,
    prerequisites = { "laser", "military-3" },
    effects = {
      { type = "unlock-recipe", recipe = "wp-shock-lance" },
    },
    unit = {
      count = 200,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
        { "military-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
    order = "e-a-w",
  },
}

-- Named sounds the script plays for the orb and the combo.
table.insert(prototypes, { type = "sound", name = "wp-shock-orb-fire", filename = SFX .. "shock-lance-orb.ogg", volume = 0.7 })
table.insert(prototypes, {
  type = "sound", name = "wp-shock-combo", filename = SFX .. "shock-lance-combo.ogg", volume = 1,
  audible_distance_modifier = 2,   -- the combo carries twice as far as normal sounds
})

-- Lavender spark particles for the shock combo.
table.insert(prototypes, {
  type = "optimized-particle",
  name = "wp-shock-spark",
  life_time = 45,
  fade_away_duration = 25,
  render_layer = "air-object",
  pictures = {
    { filename = GFX .. "entity/shock-spark.png", size = 32, scale = 0.35, blend_mode = "additive", draw_as_glow = true },
    { filename = GFX .. "entity/shock-spark.png", size = 32, scale = 0.5, blend_mode = "additive", draw_as_glow = true },
    { filename = GFX .. "entity/shock-spark.png", size = 32, scale = 0.7, blend_mode = "additive", draw_as_glow = true },
    { filename = GFX .. "entity/shock-twinkle.png", size = 32, scale = 0.6, blend_mode = "additive", draw_as_glow = true },
  },
})

-- Supernova combo sprites and the crater decal, all drawn by the script.
local function fx_sprite(name, file, width, height, scale, blend)
  table.insert(prototypes, {
    type = "sprite", name = name, filename = GFX .. "entity/" .. file,
    width = width, height = height, scale = scale, blend_mode = blend,
  })
end
fx_sprite("wp-supernova-core", "supernova-core.png", 512, 512, 0.5, "additive")       -- 8 tiles across
fx_sprite("wp-supernova-flare", "supernova-flare.png", 1024, 96, 0.5, "additive")     -- 16 x 1.5 tiles
fx_sprite("wp-supernova-shell", "supernova-shell.png", 512, 512, 0.5, "additive")     -- ring radius 3.2 tiles
fx_sprite("wp-supernova-equator", "supernova-equator.png", 512, 512, 0.5, "additive") -- ring radius 3.2 tiles
fx_sprite("wp-supernova-volume", "supernova-volume.png", 256, 256, 0.5, "normal")    -- radius 2 tiles
fx_sprite("wp-supernova-haze", "supernova-haze.png", 256, 256, 0.5, "additive")       -- radius 2 tiles
fx_sprite("wp-shock-crater", "crater.png", 256, 256, 1, "normal")                     -- radius ~3.4 tiles
fx_sprite("wp-shock-crater-bloom", "crater-bloom.png", 384, 384, 1, "additive")       -- bigger canvas for the bloom
fx_sprite("wp-shock-crater-glow", "crater-glow.png", 256, 256, 1, "additive")

data:extend(prototypes)

-- Laser damage and laser shooting speed research also boost the Shock Lance.
for _, tech in pairs(data.raw.technology) do
  if tech.effects then
    local extra = {}
    for _, effect in pairs(tech.effects) do
      if (effect.type == "ammo-damage" or effect.type == "gun-speed") and effect.ammo_category == "laser" then
        table.insert(extra, { type = effect.type, ammo_category = CATEGORY, modifier = effect.modifier })
      end
    end
    for _, effect in pairs(extra) do table.insert(tech.effects, effect) end
  end
end
