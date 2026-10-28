# HiFi Companion v0.1 — revert point

Annotated git tag **`v0.1`** marks the working EQ **before** the side-panel UX redesign (no side knobs / ALL CAPS side card). Use this only if Mert asks to go back to 0.1.

| | |
|---|---|
| **Tag** | `v0.1` |
| **Commit** | `fd09485ee708cbaf7a1f1744ab463a334099d794` |
| **Message** | HiFi Companion 0.1 — revert point before side-panel UX |
| **Stamp / ver** | `window-chrome-v7` / `7` |
| **Binary copy** | `~/Applications/HiFiCompanion-0.1.app` |

Current approved line is **`v0.2`**. See [eq-v0.2-revert.md](eq-v0.2-revert.md).

## How to revert

**Run the old binary (no git change):**

```bash
open ~/Applications/HiFiCompanion-0.1.app
```

**Inspect without moving a branch:**

```bash
git fetch origin tag v0.1
git checkout v0.1
```

**Hard-reset a branch onto v0.1 (destructive to later commits on that branch):**

```bash
git fetch origin tag v0.1
git checkout <the-branch-you-mean-to-rewind>
git reset --hard v0.1
# then rebuild + ditto to ~/Applications/HiFiCompanion.app if needed
```

Do not delete tag `v0.1` unless intentionally retiring the snapshot.
