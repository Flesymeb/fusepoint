# FPS viewmodel switcher component

Open `project.godot` in Godot 4.7 and run the demo. Scroll the mouse wheel or
press `Q`/`1`/`2` to switch between the AK-74M and Saiga-12 profiles; hold right
mouse to preview ADS, left mouse to fire or hold, `M` to toggle semi/auto,
and `R` to reload. Semi fire uses a short transient, while auto fire sustains
while held. The demo starts in auto fire.

The bundled AK-74M and Saiga-12 parameters are manually tuned and ready to use
as-is. Do not casually change weapon scale, source rotation, Hip/ADS offsets,
camera near values, Saiga reload-only offset, feedback-node placement,
fire/recoil timing, audio timing, or animation mappings. Adjust those values
only when replacing a whole profile with a new retargeted source, or when
runtime screenshots and contract tests prove a concrete integration defect.

The demo also includes built-in muzzle flash, switch, aim, reload, fire, walk
and run feedback. See `COMPONENT.md` for the binding contract and
`SOURCE_ATTRIBUTION.txt` for required attribution. The default primary weapon is
the bundled AK-74M profile.
