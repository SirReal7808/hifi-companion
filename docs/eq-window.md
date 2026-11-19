# EQ window

The floating EQ window: layout, interaction, visual target, window chrome, and the **locked compact footer**. The layout and interaction shipped in v0.2; the **native Liquid Glass styling** (below) was agreed with Mert on 2026-10-31 from concept mockups and replaces the v0.2 look. Do not reopen any decision here unless Mert asks.

![EQ window, native Liquid Glass (dark, 0.5)](media/eq-v0.5-dark.jpg)

Light: [media/eq-v0.5-light.jpg](media/eq-v0.5-light.jpg). Sweep → FIX PEAK: [media/sweep-fix-peak.gif](media/sweep-fix-peak.gif). Regenerate all three with `scripts/readme-media.sh`. Older dark look (0.3.1): [media/eq-v0.3.1-dark.jpg](media/eq-v0.3.1-dark.jpg).

With Bypass EQ on, the graph turns gray: [media/eq-v0.3.1-dark-bypass.jpg](media/eq-v0.3.1-dark-bypass.jpg). The v0.2 look it replaces: [media/eq-v0.2-dark.jpg](media/eq-v0.2-dark.jpg).

## Layout

One window, **no tabs**. Top to bottom:

1. **Toolbar** — leading inset for the close button, Undo / Redo in **one glass capsule** split by a hairline (⌘Z / ⇧⌘Z, also ⌘Y), centered title "HiFi Companion", trailing glass **profile capsule** (shows the active profile name, `*` when dirty, "Untitled" when none).
2. **Response graph** — always visible, full width. Press-drag is always the sweep.
3. **Middle** — band list on the left, **side glass** on the right (300 pt).
4. **Footer chips** — **Add Band** (left, with a plus) and **Reset** (right) on the window background, the same glass capsule as the toolbar controls.

The menu bar panel and Settings own the equalizer switch, output, Apple Music Mode and appearance. No status or helper lines in the EQ chrome (bit-perfect, peak boost, needle hints); the clipping warning is a **graph overlay**, never an in-flow banner (banners grew the height and pushed FIX PEAK / FIX DIP under the footer): a glass pill at the graph's bottom-trailing corner, just above the Hz labels (the needle label owns the top edge) — warning icon, "Clipping risk", how far output + peak boost goes over 0 dB, and a **Fix** button that lowers Output to the safe ceiling (`setOutputGainToSafe`; Auto Gain is left as it is).

## Bands

- Show **used bands only**; Add Band adds one (max **10**).
- The rows sit in **one rounded glass group** separated by hairlines (Settings style), not separate cards.
- Row: ↑↓ reorder, index, filter type menu (PK / LS / HS, glass capsule), then **FREQ / GAIN / Q** — a small caps label over a large value (17 pt, unit smaller and secondary; double-click to type), per-band enable (speaker), remove (×).
- **No color dot.** The band color lights the row from its **leading edge**: a soft radial glow plus a thin vertical light line that fades at both ends. The selected band (clicked, or dragged on the graph) glows stronger. A bypassed band has no light.
- Moving a band with ↑ / ↓ **slides the rows** (short, quiet animation); add / remove stay unanimated (window-size animation crashes AppKit).
- **No knobs on band F / G / Q.** Knobs exist only on Output Gain and Gain Level in the side glass.
- Drag graph handles for F and G; Q is typed. Reorder with **↑ / ↓ only** (no list drag). Indices match graph handles 1…N.
- Filter types: peaking (PK, default), low shelf (LS), high shelf (HS). Switching peaking → shelf sets Q to 0.7.
- Limits: 20 Hz–20 kHz, ±14 dB, Q 0–10.

## Sweep (always on the graph)

- Press-drag plays the tone; release mutes; the needle parks with a small frequency label. Only one needle. The line breaks around the label and continues above it; while held it is solid orange and 2 pt, parked it is a thin dashed line.
- **FIX PEAK** = you heard a peak → add a **cut** (−3 dB). **FIX DIP** = you heard a dip → add a **boost** (+3 dB). Q **3**. The side panel shows `Peak -3 dB · Dip +3 dB`.
- **LEVEL** (sweep tone level): default **−12 dB**, range **−20…0 dB**.
- Audio behavior (wake engine, mixing before PEQ): [audio-path.md](audio-path.md#sweep).

## Side glass

One glass group (300 pt wide) with two sections split by a hairline:

| Section | Contents |
|---|---|
| **Output** | Framed **OUTPUT** stack (label · knob · dB field). Beside it, top to bottom: **Auto Gain** switch; a short centered hairline; **BYPASS EQ** button (orange glass while on); **Gain Match** switch. Knob / field disabled while Auto Gain is on. |
| **SWEEP** | Header `SWEEP` with `Peak -3 dB · Dip +3 dB`; framed **LEVEL** stack (same chrome as OUTPUT) + **FIX PEAK** / **FIX DIP** glass buttons lit from the leading edge (blue / orange), same height as the LEVEL stack; caption "Click and drag on the graph to sweep" |

Details that are decided:

- ALL CAPS section and stack labels; FIX PEAK / FIX DIP wording; no steppers. "SWEEP", not "Tone generator": the feature is the graph sweep.
- Switches are native mini switches (Auto Gain, Gain Match). Bypass EQ stays a **button** so the A/B state is obvious.
- Knobs (both 44 pt): quiet radial, −135°…+135°, vertical drag. Scroll 0.1 dB per tick (max 0.25 dB per event). **Trackpad inverted** (two-finger drag down decreases dB); mouse wheel unchanged.
- SF Pro via `.font(.system(…))` — never `.rounded`. No emoji.
- FIX PEAK / FIX DIP are the primary feature of the app; keep them large.

## Profiles

Save / load named profiles from the toolbar menu. Save opens a small sheet (`SaveProfileSheet`) prefilled with the active name — a sheet because an `.alert` TextField sometimes opened empty; an existing name asks **"Already exists. Overwrite?"**. Delete confirms. Loading a profile marks it active (clean); edits mark it dirty (`*`). Reset clears the active profile.

## Reset

Reset confirms with an `.alert` ("Remove all bands and restore Output Gain to 0 dB."). Use `.alert`, not `.confirmationDialog` (its buttons did not receive clicks in this window). Middle hit-testing is disabled while an alert is up.

## Window height

- Width locked at **790 pt** (900 until 2026-10-31; narrowed with the glass styling). Height is exactly **H(N)** with `min == max`; the window is not resizable.
- The middle hugs `max(band list, measured side glass)`; the band list is never shorter than the 4-band layout. The list scrolls when it is taller than the middle.
- On short screens: shrink the graph first (228 → min 140 pt), then the middle; clamp to `visibleFrame − 16`. Never clip the side glass to make it fit.
- Height changes only when the band count, the measured side height, or the screen cap changes. The window keeps its top-left corner when it resizes. Sizing waits while the toolbar strip drags the window and runs once on the drop, using the screen the window is on.
- Sizing logic: `PEQPanelMetrics` and `ExactHeightEQPanel` in `PEQPanelController.swift`.

## Compact footer — locked (2026-10-27)

Approved at `eq-footer-compact-v4` / 0.2.0 (19). **Do not regress** unless Mert explicitly changes it. If a layout or height change would violate it, stop.

1. **No** separate dark footer bar, strip, or fixed-height footer container.
2. **Add Band** and **Reset** sit on the **main window background**.
3. The pad **above** those chips **equals** the pad **below** (`PEQPanelMetrics.footerChipInset` = 12 on both sides; `footerClearance == 0`).
4. The side glass keeps its bottom **rounded corners and drop shadow fully visible**.
5. Window height hugs `max(band list, side glass) + compact chrome`; no void under the bands beyond the taller column (`sideShadowBleed == 0`).

Never (unless Mert asks):

- `.clipped()` / `.compositingGroup()` on the middle column (cuts the glass corners and shadow).
- A `GeometryReader` or fixed-height shell around the side glass that masks overflow.
- A footer layer that covers the bottom of the side glass.
- `layoutPriority` on the middle that expands it and opens a gap above the chips.
- Growing H(N) with fake bleed under a short side panel.

`testCompactFooterInvariant` in `PEQPanelMetricsTests` must stay green. Cursor users also get [`.cursor/rules/eq-compact-footer.mdc`](../.cursor/rules/eq-compact-footer.mdc).

![Bottom-right: unclipped glass corners and shadow, equal chip insets](media/eq-v0.2-footer-corner.jpg)

## Window chrome

- A normal `NSWindow` at **normal** level (not an always-on-top `NSPanel`); other apps can cover it. Opening from the menu activates it once. While it is open the app is a regular app (Dock icon, ⌘Tab), so it can be brought back after another app took the focus (`DockPresence`).
- Style: titled + closable + miniaturizable + `fullSizeContentView`; transparent titlebar, hidden title. **Not resizable.**
- **Dragging:** the window is not movable by the system (`isMovable = false`). A transparent 60 pt strip behind the toolbar (`EQWindowDragArea`) moves it by the pointer's travel, so it stays under the pointer across displays; toolbar buttons sit above the strip. While it drags, every other frame change is dropped and sizing waits for the drop ([pitfalls](pitfalls.md#eq-window-jumped-when-dragged-to-the-other-display)).
- Miniaturize and zoom buttons are alpha-hidden and disabled (they keep their layout slots so close sits in the standard position). `windowShouldZoom` → false; `fullScreenNone`.
- Close button at the standard titled-window inset `(7, 6)`. Never measure insets with a throwaway window (launch crash — see [pitfalls.md](pitfalls.md)).
- The window **and its hosting controller** are recreated on every open (a reused window let the hosting view inflate the height; a reused hosting controller never re-measured the side glass, which clipped Add Band / Reset).

## Visual target

**Native Liquid Glass, dark first** (Mert, 2026-10-31): the same language as the Settings window — system materials, glass capsules for chrome controls, one grouped container for the bands, native mini switches. Concept mockups: [EQ Liquid Glass Concepts](https://claude.ai/artifact/HsdzgcS4io6eGiE9UrmvYC) (private; board "A · Native glass, knobs (dark)" is the target). Light mode is not designed separately: it follows from the same materials and semantic colors.

Materials and feel:

- System materials (`.regularMaterial` and friends) with a light top rim and a soft shadow; no hand-painted opaque plates.
- Toolbar controls, profile menu, filter-type menus and footer chips share **one glass capsule style**.
- Color is reserved for meaning: band colors (graph and row edge light), accent for switches, orange for Bypass EQ on, blue / orange for FIX PEAK / FIX DIP.

Graph:

- Log 20 Hz–20 kHz; dB grid at ±12 / ±6 / 0 with small **axis labels** (dB on the left, Hz along the bottom). Thin continuous curve.
- One numbered **glass handle** per band — exactly 1…N, no duplicates, matching the list order: a faint band-color tint, a thin band-color rim, a top highlight, the number in the primary text color.
- Soft multi-color wash under the curve following band colors. Visible but soft — not neon.
- **Bypass EQ on: the whole graph turns gray** (curve, wash, handles); handles stay editable.
- One parked sweep needle with a small frequency label (11.5 pt; the line never runs through the text).

Still true from v0.2: F / G / Q values agree between the graph and the rows; no extra floating badges, duplicate needles, or random glyphs.

Superseded: the v0.2 frosted look and the 2026-10-26 reference mockups (`media/reference-mockup-*.png`, kept for history). The earlier "sparse flat light Liquid Glass" concept stays rejected; the native glass above is a different direction.

## Still deferred

Nothing. (Band reorder motion shipped with the glass styling.)
