# EQ window visual target

Approved by Mert on 2026-10-26. Layout is the side-control layout. Styling follows the **user-supplied references**, not the earlier sparse Liquid Glass light concept.

## Reference images

User refs (intent; generated refs may contain mistakes — intent below wins):

- Light: [media/hifi-companion-eq-user-ref-light.png](media/hifi-companion-eq-user-ref-light.png)
- Dark: [media/hifi-companion-eq-user-ref-dark.png](media/hifi-companion-eq-user-ref-dark.png)

Shipped v0.2 side panel + compact footer (match these, do not regress):

- Compact footer (locked): [media/eq-footer-compact.jpg](media/eq-footer-compact.jpg)
- Unclipped bottom-right glass + shadow: [media/eq-footer-compact-br.jpg](media/eq-footer-compact-br.jpg)
- Side knobs: [media/eq-side-ux-knobs-4bands.jpg](media/eq-side-ux-knobs-4bands.jpg)
- ALL CAPS side copy: [media/eq-side-ux-caps-4bands.jpg](media/eq-side-ux-caps-4bands.jpg)

## Materials and feel

- Soft frosted glass: translucent panels, rounded “cushion” controls, soft outer shadow and a light top rim highlight.
- Window sits on a quiet background. Content areas are frosted plates, not a flat opaque sheet.
- Band list: one soft glass group with rounded rows, not a plain Settings-style table.
- Right column: one soft glass group. Three equal sections (Output Gain, Bypass EQ, Tone Gain) split by thin hairlines.
- Toolbar: circular undo/redo, centered title, trailing glass profile menu.
- Footer: pill/cushion **Add Band** and **Reset** on the **main window background** — not a separate dark footer bar or strip.
- Compact footer (locked 2026-10-27): pad above Add Band/Reset equals the pad below them. The right Output/Tone glass keeps its bottom rounded corners and drop shadow fully visible; never clip with `.clipped()`, an overlay, ExactHeight, or a footer layer. Window height hugs `max(band list, side glass)` plus that compact chrome. Do not inflate a void under the bands.

## Graph

- Full width, log 20 Hz–20 kHz, dB grid.
- Thin continuous curve. One numbered colored handle per band (exactly 1…N, no duplicates).
- Soft multi-color wash under the curve that follows band colors (blue → teal → green → yellow → orange → pink). Visible but soft — not neon, not a heavy fill.
- Optional parked sweep needle with a small frequency label. Only one needle.

## Controls (match the references)

- Output Gain and Tone Gain: glass numeric fields + **knobs** (v0.2); Auto under Output Gain.
- Bypass EQ: prominent toggle; Gain Match under it.
- Peak and Dip: large side-by-side cushion buttons with simple peak/dip curve icons. Primary feature of the app.
- Band rows: color dot, ↑↓, index, PK popup, F / G / Q text, remove. Same structure every row.

## Fix when regenerating or implementing

- Unique handle numbers 1…N matching the list order.
- Consistent F/G/Q values between graph and rows.
- No extra floating badges, duplicate needles, or random glyphs.
- SF Pro–like typography (`.font(.system(…))`); no emojis; no `.rounded`.

## Rejected

- The sparse flat light “Liquid Glass” concept is **not** the target. Do not revive it as the visual direction.
