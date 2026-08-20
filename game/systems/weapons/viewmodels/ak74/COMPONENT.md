# Reusable FPS viewmodel switcher

The production entry point remains
`addons/fps_ak74_viewmodel/fps_ak74_viewmodel.tscn` for compatibility. Despite
the historical directory name, it is now a general profile-driven viewmodel
switcher with an embedded feedback node. Use the registered product
materialization for the complete portable component root: addon, both model
rigs, profiles, `audio/`, `effects/`, license, attribution, and receipt. Then
instance the original production scene directly under the player's `Camera3D`.
Do not manually extract the addon or either gun as a smaller substitute.

```gdscript
@onready var viewmodel: FPSViewmodelSwitcher = $Camera3D/FPSViewmodelSwitcher

func fire() -> void:
	viewmodel.play_clip(&"fire")

func reload_weapon() -> void:
	viewmodel.play_clip(&"reload")

func equip_secondary() -> void:
	viewmodel.equip_weapon_id(&"saiga12")

func set_ads(enabled: bool) -> void:
	viewmodel.set_aiming(enabled)
```

The default component proves the framework against two complete, independently
animated hands-and-weapon rigs:

- `ak74m`: AK-74M clip set plus calibrated procedural ADS.
- `saiga12`: idle, walk, run, fire, fast reload and full reload, with
  its own camera-space Hip/ADS framing.

The AK-74M slot uses the repository's bundled AK-74M source pack as its
runtime backing.

The mouse wheel cycles complete profiles with a lower/replace/draw/raise
transition. `Q` and number keys `1`/`2` perform the same action in the demo.
Holding right mouse uses the active profile's ADS values and releasing it
returns to that profile's Hip pose. Left mouse drives fire hold/release,
`M` toggles semi/auto, `R` reloads, and the feedback child plays a short
single-shot fire transient in semi-auto, a sustained auto-fire bed while the
trigger is held, reload, switch, aim and movement audio plus the muzzle flash.
The demo starts in auto fire by default.
A product should keep the shipped weapon scale, angle, recoil, framing and
animation mapping intact unless it is replacing the complete profile with a
new retargeted asset set.
A product integration should first bind ammo, ballistics, HUD, and input to the
existing public API without changing the component scene tree or profile
values. Wrapper-level changes are preferred; internal retuning requires matched
before/after runtime evidence and rerunning the supplied contract captures.
A product
may disable `handle_mouse_wheel` or `handle_right_mouse` and call the public
methods from its own input/controller layer. If it disables the built-in wheel
handler, its replacement must call `cycle_weapon()` or `equip_weapon()` and
observe `weapon_changed`; playing only a lower/raise transition does not
switch weapons. Product weapon state and HUD must key ammo, name and tuning by
`current_weapon_id()` rather than hard-code one weapon id.

This component owns viewmodel presentation and profile switching. It does not
provide ballistics, damage, enemy health or hit feedback. A product must bind
its fire event to an authoritative ray/projectile and damage pipeline; calling
`play_clip(&"fire")` alone is intentionally not a combat implementation.

## Replacing or adding a weapon

Do not replace only the visible rifle mesh while retaining unrelated hands or
animations. Create another `FPSViewmodelProfile` resource and assign:

1. one `PackedScene` containing the complete coupled hands, weapon, skeleton
   and `AnimationPlayer`;
2. that source's axis correction;
3. independently rendered Hip and ADS position/scale/near-plane values;
4. its real authored animation names.

Append the profile to `weapon_profiles`. No weapon-specific axis, animation or
framing constants belong in the switcher script. Missing optional clips such as
inspect, hide or reload variants return `false`; the product must omit the
state, author it, or choose another source instead of relabeling an unrelated
animation.

Every new profile still requires fresh rendered Hip/ADS/fire/reload checks.
Passing the structural contract proves that the scene and mappings load; it
   does not prove that another model shares the AK-74M or Saiga-12 camera framing.

## Validation

```bash
GODOT=/absolute/path/to/Godot_v4.7-stable_linux.x86_64
mkdir -p artifacts

"$GODOT" --headless --path . \
  --script res://systems/weapons/viewmodels/ak74/tests/viewmodel_component_contract.gd

xvfb-run -a "$GODOT" --path . \
  --script res://systems/weapons/viewmodels/ak74/tests/capture_component.gd -- idle artifacts/ak-idle.png ak74m

xvfb-run -a "$GODOT" --path . \
  --script res://systems/weapons/viewmodels/ak74/tests/capture_component.gd -- inspect artifacts/saiga-inspect.png saiga12

xvfb-run -a "$GODOT" --path . \
  --script res://systems/weapons/viewmodels/ak74/tests/capture_switch_sequence.gd -- artifacts/viewmodel-switch
```

`scenes/viewmodel_demo.tscn` is a calibration preview only. Do not copy its
floor, labels, markers or reticle into a shipped game. The production addon
contains no diagnostic panel or large UI block.
