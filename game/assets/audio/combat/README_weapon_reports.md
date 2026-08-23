# Fusepoint bounded firearm reports

`ak74_single_report_product.wav` and `enemy_rifle_single_report.wav` are
product-owned derivatives of the retained CC-BY-4.0 AK-74M component report
`systems/weapons/viewmodels/ak74/audio/sfx_fire_single.wav` (SHA-256
`1cd32d5807e217ab32e0376f7c72af976570585e6cf41ddcfb78c9573e9e5755`).
The retained source is unchanged.

The player derivative starts at 6 ms, retains 460 ms of attack, body and short
decay, high/low-pass conditions the body, and uses 4 ms attack plus 100 ms tail
fades. The enemy derivative starts at 12 ms, retains 520 ms, uses a distinct
band and gain, and uses 6 ms attack plus 120 ms tail fades. These physically
bounded PCM resources end in the audio server without a render-thread timer.
They intentionally do not copy bytes from source frame zero and are not an
arbitrary prefix used only to meet a duration cap.

Source license and attribution remain in
`systems/weapons/viewmodels/ak74/SOURCE_ATTRIBUTION.txt`.

The current concrete (`hammer_fall.wav`, 1.040 s) and metal
(`metal_twang.wav`, 1.962 s) candidates are retained only as isolated debug
audition stems. Their long ringing bodies can mask or resemble the player
report, so ordinary player world-surface hits render impact VFX without these
two cues. Character-hit feedback and bounded enemy spatial reports remain
enabled. No source PCM is sliced at runtime.

The active player report is now `player_rifle_single_report.wav`, the original
231 ms CC0 source published as Freesound 258198 by wadaltmon. It is bound at the
product adapter boundary to the retained component's `FireAudio` node. The
physical file EOF supplies the report boundary; the old product PCM derivative
is retained only as provenance history and is not used by normal play or tester
acceptance lanes. Exact source and license metadata live in
`player_rifle_single_report.source.json`.
