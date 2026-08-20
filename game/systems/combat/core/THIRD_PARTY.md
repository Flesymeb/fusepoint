# Third-party assets

The combat code is MIT-licensed. The standalone showcase also retains the
notices shipped under `systems/actors/humanoid` for its replaceable character
presentation.

`addons/fps_combat_core/assets/pain_hud.png` is “1920 x 1080 PainHud CC0” from
OpenGameArt, released under CC0 1.0:
https://opengameart.org/content/1920-x-1080-painhud-cc0

The image is used as a transparent, event-driven damage/death vignette. It is
not a health value source and remains hidden until authoritative `FPSHealth`
events activate it.

`systems/actors/humanoid/assets/weapons/primary_rifle/m4_rifle.glb` is “M4
Rifle” by Charlie Baldwin, downloaded from Sketchfab and licensed under CC BY
4.0:
https://sketchfab.com/3d-models/m4-rifle-5029ec1a279e4834be88d5c46dae0515
https://sketchfab.com/charlieatron

The combat component uses the complete authored multi-part rifle as a static
third-person enemy weapon. It has exactly one attached magazine and no
detached showcase ammunition.
