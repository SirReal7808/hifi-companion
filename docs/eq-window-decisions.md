# EQ window decisions

Interaction and layout for HiFi Companion’s floating EQ window. Shipped on **`v0.2`**. Do not reopen these unless Mert asks.

## Structure

- One floating EQ window — **no Tune/Sweep tabs**. Graph press-drag is always the tone sweep.
- Menu bar keeps Pass-through / SB / lock / Appearance only.
- Toolbar: Undo/Redo (⌘Z / ⇧⌘Z), centered title, trailing profile menu.
- Right **side glass** (three sections, hairlines): Output Gain (knob + dB + Auto), Bypass EQ + Gain Match, Tone Gain (knob + Peak / Dip).
- Band list on the left (used bands only). **Add Band** and **Reset** at the bottom on the **window background** — not a footer strip. Reset confirms.
- Response graph always visible. No status/helper lines in the chrome (bit-perfect, peak boost, needle hint). Clipping warning is a graph overlay only — never an in-flow banner (banners grew height and shoved Peak/Dip).

## Bands

- Show **used bands only**; **Add Band** adds (max 10).
- Row: color dot, ↑↓, index, PK/LS/HS, `F:` / `G:` / `Q:` text (double-click to type), per-band enable, remove.
- **No knobs on band F/G/Q.** Knobs exist only on Output Gain and Tone Gain in the side panel.
- Drag graph handles for F and G; Q via text. Reorder with **↑/↓ only** (no list drag). Indices match graph 1…N.
- Filter types: peaking default; **LS** / **HS**. Peak→shelf sets Q to 0.7.
- Window height is exact `H(N)` (`min == max`). Middle hugs `max(band list, measured side glass)`. List scrolls when the list is taller than the middle. On short screens, graph shrinks first (down to 140 pt), then middle; clamp to `visibleFrame − 16`.
- **Compact footer, locked 2026-10-27:** no dark footer strip. Equal insets above and below Add Band / Reset. Right glass bottom corners and shadow stay fully visible. Height = `max(bands, side glass)` + that chrome. Do not regress; shot [media/eq-footer-compact.jpg](media/eq-footer-compact.jpg). Rule: [`.cursor/rules/eq-compact-footer.mdc`](../.cursor/rules/eq-compact-footer.mdc).

## Sweep (always on graph)

- Press-drag plays tone; release mutes; needle parks. One needle.
- **Peak** = heard a peak → add **cut**. **Dip** = heard a dip → add **boost**. Q default **3**.
- Tone Gain: default **−12 dB**, range **−20…0**.
- Side labels: FIX PEAK / FIX DIP (ALL CAPS). Large side-by-side cushion buttons.

## Side panel (post–v0.1, included in v0.2)

v0.1 was the last EQ **without** this side UX. Do not silently revert to text-only Output/Tone unless Mert asks for `v0.1`.

- ALL CAPS section labels.
- Glass knobs: quiet radial, −135°…+135°, vertical drag; scroll 0.1 dB/tick (max 0.25 dB/event); **trackpad inverted** (two-finger drag down decreases dB); mouse wheel unchanged.
- OUTPUT GAIN framed like GAIN LEVEL.
- Hairline above TONE GENERATOR (between Bypass and Tone).
- SF Pro (`.font(.system(…))`, not `.rounded`).

Shots: [media/eq-side-ux-knobs-4bands.jpg](media/eq-side-ux-knobs-4bands.jpg), [media/eq-side-ux-caps-4bands.jpg](media/eq-side-ux-caps-4bands.jpg).

## Profiles

Save / load named EQ profiles; show active name (dirty `*`); confirm overwrite; delete confirms.

## Visual

Follow [eq-visual-target.md](eq-visual-target.md). Soft frosted glass; system light/dark + menu Appearance. Native materials so it matches macOS 27 on device.

**Still deferred:** extra reorder-motion polish. Band handle colors and graph wash are in.

## Window chrome

- `NSWindow` at **normal** level (not always-on-top `NSPanel`).
- Style: titled + closable + `fullSizeContentView`. **Not resizable.** Green zoom hidden/disabled; `windowShouldZoom` → false.
- Standard close traffic-light inset. Do not measure insets with a throwaway window (launch crash — [pitfalls.md](pitfalls.md)).
- Width locked **900**.
