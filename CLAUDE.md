# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is
A SketchUp Ruby extension that procedurally generates building facades. Selected groups/components are filled with stacked block geometry driven by `.mgz` pattern files (JSON). A bundled `UI::HtmlDialog` (`manager.html`) lets users browse, edit, and preview patterns visually.

## File map
| File | Role |
|------|------|
| `MagArkido.rb` | Extension loader (`SketchupExtension`, version 0.5.0) |
| `MagArkido/MagArkido_Core.rb` | All Ruby logic: geometry generation, expression resolver, toolbar, dialog callbacks |
| `MagArkido/Resource/manager.html` | Full single-file UI: pattern grid, visual block editor, ISO canvas preview |
| `MagArkido/Resource/manager.css` | Light theme stylesheet for the dialog |

## SketchUp install path
`~/Library/Application Support/SketchUp 2026/SketchUp/Plugins/`

## Deploy & reload
After editing, copy changed files to the plugins folder:
```bash
cp MagArkido/MagArkido_Core.rb ~/Library/Application\ Support/SketchUp\ 2026/SketchUp/Plugins/MagArkido/MagArkido_Core.rb
cp MagArkido/Resource/manager.html ~/Library/Application\ Support/SketchUp\ 2026/SketchUp/Plugins/MagArkido/Resource/manager.html
cp MagArkido/Resource/manager.css ~/Library/Application\ Support/SketchUp\ 2026/SketchUp/Plugins/MagArkido/Resource/manager.css
```

Then in the SketchUp Ruby Console, define the reload shortcut once per session:
```ruby
def rel
  MagArkido::Core.reset_mgr rescue nil
  load File.join(Sketchup.find_support_file('Plugins'), 'MagArkido/MagArkido_Core.rb')
end
```

Then type `rel` to reload. **Important:** Load `MagArkido_Core.rb` directly — loading `MagArkido.rb` only re-registers the extension and does not reload any code. After `rel`, close and reopen the manager dialog via the toolbar so callbacks are re-registered on the fresh dialog instance.

---

## Pattern format (`.mgz`)
JSON with two top-level keys. Two valid PTNS structures are supported:

**Flat** (legacy):
```json
{ "CLRS": { "BDY": "#aabbcc" }, "PTNS": { "PatternName": [ ...blocks ] } }
```

**Nested** (current, with categories):
```json
{ "CLRS": { "BDY": "#aabbcc" }, "PTNS": { "CategoryName": { "PatternName": [ ...blocks ] } } }
```

`merge_ptns()` in `MagArkido_Core.rb` normalises both formats on load. Flat patterns land in a `"Default"` category. Always write new files in the nested format.

Each block is either a **positional array** `[x,y,z,w,d,h,mat,detail,face,seg,offset]` or a **named-key object** `{x,y,z,w,d,h,mat,detail,face,seg,offset}`. Both are normalised in Ruby via `normalise_block()` and in JS via `arrToBlock()`.

### Block fields

| Field | Type | Description |
|-------|------|-------------|
| `x` | number/expr | Position along X axis (red axis in SketchUp) |
| `y` | number/expr | Position along Y axis (green axis, depth) |
| `z` | number/expr | Position along Z axis (blue axis, height/up) |
| `w` | number/expr | Width — extent along X |
| `d` | number/expr | Depth — extent along Y |
| `h` | number/expr | Height — extent along Z |
| `mat` | string | Material key matching a `CLRS` entry (e.g. `"BDY"`, `"SLD"`) |
| `detail` | 0/1/2 | `0` = no lines, `1` = horizontal lines (`dv1`), `2` = vertical lines (`dv2`) |
| `face` | 0–5 | Which face the detail lines are drawn on (0 = front/Y+, 1–5 = other faces) |
| `seg` | number/expr | Number of detail line segments (minimum 2) |
| `offset` | number/expr | Inset of detail lines from block edges |

All numeric fields accept **expressions** (see Expression system below).

### Authoring a pattern by hand

Blocks are placed in **model units** (metres if the model is set to metres). All blocks share the same coordinate space — position `(0,0,0)` is the bottom-front-left corner of the pattern. The pattern is then scaled to fill the target group's bounding box, so only the **relative proportions** between blocks matter, not the absolute numbers.

```json
{
  "CLRS": { "BDY": "#5a7fa0", "SLD": "#2d3a45" },
  "PTNS": {
    "TierBuilding": {
      "SimpleTower": [
        { "x": 0, "y": 0, "z": 0, "w": 10, "d": 10, "h": "lv(t,3.5)", "mat": "BDY", "detail": 1, "face": 0, "seg": 6, "offset": 0 },
        { "x": 0, "y": 0, "z": 0, "w": 5,  "d": 5,  "h": "lv(t,3.5)*1.2", "mat": "SLD", "detail": 0, "face": 0, "seg": 6, "offset": 0 }
      ]
    }
  }
}
```

**Tips:**
- Use `lv(t, 3.5)` for height so block count scales with the target building's height (3.5 = floor height in metres).
- `r1`/`r2`/`r3` are per-instance random 0/1 bits — useful for variation: `"x": "r1*2"` shifts a block 0 or 2 units randomly.
- `CLRS` entries are merged into the SketchUp material list on load. Hex strings (`"#rrggbb"`) and integers are both valid.
- Blocks with zero or negative `w`/`d`/`h` (e.g. when `lv()` resolves to 0 on a tiny group) are skipped silently.

---

## Expression system
Any numeric field (`x y z w d h seg offset`) can hold a string expression instead of a number.

Supported tokens:
- `r1`, `r2`, `r3` — random 0 or 1, fixed per building instance
- `lv(t, n)` — floor count = `target_height_metres / n` (rounds to integer)
- `h`, `w`, `d`, `x`, `y`, `z`, `seg`, `offset` — resolved values of **sibling fields in the same block**
- Standard arithmetic: `+ - * / ( )`

Cross-field refs work via **two-pass resolution**: pass 1 resolves `r1/r2/r3/lv()`, pass 2 substitutes the now-numeric peer values. Circular refs are not supported.

**Ruby**: `resolve(expr, t, r1, r2, r3, block_fields = nil)` — whitelist-validates before `eval()`.  
**JS**: `evalExpr(v, r1v, r2v, r3v, ph, fields)` in `manager.html`.

---

## Geometry pipeline (`create(t, pattern_data, detail, ptn_name)` in Ruby)
1. Add a container group `e` inside the target entity.
   - `Sketchup::Group` → `e = t.entities.add_group`
   - `Sketchup::ComponentInstance` → `e = t.definition.entities.add_group`
2. Capture target bounds **before** adding geometry — `t.bounds` for groups, `t.definition.bounds` for components. Capturing after inflates bounds and breaks scale.
3. Resolve all block expressions (two passes). Skip blocks with zero/negative dimensions.
4. Build cube geometry + detail lines (`dv1` = horizontal, `dv2` = vertical). Each block becomes a named group `"Block N"` inside `e`. `dv1`/`dv2` guard against empty face/edge sets and return early rather than crash.
5. Randomly rotate 0/90/180/270° **only on real apply** (`detail == 0`). Test skips rotation so canvas matches.
6. Move to origin, then **non-uniform scale** to exactly fit the target bounding box per axis.
7. Erase all pre-existing entities in the target (`t.entities` for groups, `t.definition.entities` for components).
8. `e.explode` — releases block groups into the target. Do not add a second explode pass.
9. Set `t.name = ptn_name` (format: `"PatternName-Category"`).

**Critical for canvas preview**: SketchUp scales X, Y, Z independently, so the ISO canvas normalises each axis by its own maximum (`x/maxX`, `y/maxY`, `z/maxZ`) to match.

---

## `choose()` return value
Returns `{ data: [...blocks], name: "PatternName", cat: "Category" }`, never a raw array. All callers use `ptn[:data]`, `ptn[:name]`, `ptn[:cat]`.

---

## Toolbar buttons
| Button | Ruby method | Description |
|--------|------------|-------------|
| Transform All | `transform_all(1)` | Apply confirmed pattern with full detail lines |
| Randomize Rotation | `rotate_all` | Rotate selected groups randomly by 90/180/270° without rebuilding geometry |
| Reset | `transform_all(0, true)` | Replace selection with the default plain cube |
| Pattern Manager | `show_mgr` | Open the HTML dialog |
| Absorb Selection | `absorb` | Convert selected group's sub-groups into editor blocks |

`@nm` controls which pattern `choose()` picks: `0` = random from all loaded, `[[cat,key],...]` = specific confirmed patterns. Set by the manager's **Confirm** button, reset to `0` when the dialog closes.

`@no_detail` (boolean) — when true, strips all detail lines from any apply regardless of block settings. Set by the **No Detail** toggle in the manager.

---

## Dialog lifecycle — critical
`show_mgr` always rebuilds the dialog when it is not already visible:
```ruby
unless @mgr&.visible?
  @mgr&.close rescue nil
  @mgr = build_manager_dialog   # registers all add_action_callback entries
end
```
This is intentional: `build_manager_dialog` is the only place callbacks are registered. If `@mgr` is reused across reloads without rebuilding, buttons in the dialog silently do nothing (the `su()` JS bridge catches the missing-method error and swallows it). `reset_mgr` nils `@mgr` so the next `show_mgr` call triggers a fresh build.

`UI.openpanel` / `UI.savepanel` / `UI.inputbox` inside any `add_action_callback` block **must** be deferred with `UI.start_timer(0, false) do ... end`.

---

## JS bridge
- JS → Ruby: `su('callbackName', jsonString)` wraps `sketchup.callbackName(arg)` in a try/catch — failures are silent in the console.
- Pattern data is pre-injected as `window.magarkidoPatterns` via `set_html` so it is available synchronously on page load.
- `testPattern` sends `{ name, cat, blocks }` — not a bare blocks array.
- `exportMgz` sends `{ name, cat, blocks }` — Ruby builds the full `.mgz` with CLRS from all loaded model materials and opens a save dialog.

---

## ISO canvas
- Isometric projection: `ip(x,y,z) = { x: cx+(x-y)*S*0.866, y: cy+(x+y)*S*0.5-z*S }`
  - Viewer direction (1,1,1): origin maps to top of canvas (furthest back); (1,1,0) maps to bottom (closest).
- Painter's sort: **ascending Z primary**, **ascending X+Y secondary**. Descending X+Y is wrong — it draws closer blocks first, making them appear behind.
- Three-face shading: top = 100%, right = 78%, left = 62% of base colour.
- Rotation buttons increment `canvasRot` (0–3); `rotateNorm()` transforms block coordinates in normalised space before `ip()`.

---

## Editor features
- Block list: drag-to-reorder (HTML5 DnD), live canvas update.
- Inspector: sliders + `fx` toggle for expression mode; expression badge shows resolved value or error inline without re-rendering the inspector (direct DOM update to preserve focus).
- `duplicateBlock()` — deep-copies the selected block and inserts it after the current position.
- **Absorb** (topbar): populates editor from selected SketchUp group's sub-groups. Units converted by `to_model_units()` (SketchUp is always inches internally).
- **Export .mgz**: opens a system save dialog, writes nested-format `.mgz` with CLRS from all currently-loaded model materials.
- **Confirm** button: sets `@nm` in Ruby to the selected patterns; does NOT apply. The toolbar Transform All button applies using whatever was confirmed.
- **No Detail** toggle: activates `@no_detail = true` in Ruby, stripping lines from all subsequent applies.

---

## Naming convention (applied geometry)
- **Parent group/instance**: `"PatternName-Category"` set on `t` after `e.explode`.
- **Child block groups**: `"Block 1"`, `"Block 2"`, … matching editor list order.

---

## Known gotchas
- `Sketchup::Group` has no `.definition` — always branch on type before calling `.definition.entities` or `.definition.bounds`.
- `dv1`/`dv2` can receive degenerate geometry (zero-height blocks from `lv()` resolving to 0). Both guard with `return if fs.empty? || fs[f].nil?` and check for empty perpendicular-edge arrays before use.
- The painter's sort secondary key must be **ascending** X+Y. Descending causes depth-order artifacts.
- `testPattern` JS sends `{ name, cat, blocks }` — not a bare array.
- Reloading `MagArkido.rb` (the loader) does nothing — always reload `MagArkido_Core.rb` directly.
