# HiFi Companion v0.2 — revert point

Annotated git tag **`v0.2`** marks the approved EQ after compact footer + laptop fit + side-panel UX. This is the **current snapshot** for new work.

| | |
|---|---|
| **Tag** | `v0.2` |
| **Commit** | `a49ad4b13be7c58d53c3a72f3e6c25665f385df4` |
| **Branch (at snapshot)** | `cursor/eq-fit-laptop-970c` |
| **Message** | HiFi Companion 0.2 — approved EQ: compact footer, laptop fit, side UX |
| **Stamp / ver** | `eq-footer-compact-v4` / `19` |
| **Binary copy** | `~/Applications/HiFiCompanion-0.2.app` |

## What this snapshot includes

- **Compact footer (locked):** no separate dark footer bar; Add Band / Reset on the main window background; equal pad above/below chips; side glass bottom corners + drop shadow unclipped.
- **Laptop fit:** ExactHeight / H(N) clamps to `visibleFrame − margin`; graph shrinks first; middle hugs `max(band list, measured side)`.
- **Side-panel UX:** knobs, ALL CAPS labels, framed OUTPUT GAIN / GAIN LEVEL, scroll soft + trackpad invert, SF Pro, tone hairline (everything after `v0.1`).

Do not regress the compact-footer invariant unless Mert explicitly changes it (see [`.cursor/rules/eq-compact-footer.mdc`](../.cursor/rules/eq-compact-footer.mdc) and [pitfalls.md](pitfalls.md)).

## How to revert

**Run the archived binary (no git change):**

```bash
open ~/Applications/HiFiCompanion-0.2.app
```

**Reinstall archive over the live app:**

```bash
pkill -x HiFiCompanion 2>/dev/null || true
ditto ~/Applications/HiFiCompanion-0.2.app ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

**Restore sources to the tagged commit (rebuild if needed):**

```bash
git fetch origin tag v0.2
git checkout v0.2
# optional: rebuild Release and ditto to ~/Applications/HiFiCompanion.app
```

**Hard-reset a branch onto the snapshot (destructive to later commits on that branch):**

```bash
git fetch origin tag v0.2
git checkout <the-branch-you-mean-to-rewind>   # never rewind main without asking Mert
git reset --hard v0.2
```

**Inspect without moving the branch:**

```bash
git checkout v0.2
```

Do not delete tag `v0.2` unless intentionally retiring the snapshot.

## Related

- Prior snapshot: [eq-v0.1-revert.md](eq-v0.1-revert.md) (`v0.1` / `HiFiCompanion-0.1.app`)
- Invariant: [eq-visual-target.md](eq-visual-target.md), [eq-window-decisions.md](eq-window-decisions.md)
