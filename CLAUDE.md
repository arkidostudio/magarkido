# MagArkido — Claude Code Context

## What this is
A SketchUp Ruby extension that procedurally generates building facades. Selected groups/components are filled with stacked block geometry driven by `.mgz` pattern files (JSON). A bundled `UI::HtmlDialog` (`manager.html`) lets users browse, edit, and preview patterns visually.

## File map
| File | Role |
|------|------|
| `MagArkido.rb` | Extension loader (`SketchupExtension`, version 0.5.0) |
| `MagArkido/MagArkido_Core.rb` | All Ruby logic: geometry generation, expression resolver, toolbar, dialog callbacks |
| `MagArkido/Resource/manager.html` | Full single-file UI: pattern grid, visual block editor, ISO canvas preview |
| `MagArkido/Resource/manager.css` | Light theme stylesheet for the dialog |

## Pattern format (`.mgz`)
JSON with two top-level keys:
```json
{ "CLRS": { "BDY": "#aabbcc", ... }, "PTNS": { "PatternName": [ ...blocks ] } }
```

Each block is either a **positional array** `[x,y,z,w,d,h,mat,detail,face,seg,offset]` or a **named-key object** `{x,y,z,w,d,h,mat,detail,face,seg,offset}`. Both formats are normalised in Ruby via `normalise_block()` and in JS via `arrToBlock()`.

## Expression system
Any numeric field (`x y z w d h seg offset`) can hold a string expression instead of a number.

Supported tokens:
- `r1`, `r2`, `r3` — random 0 or 1, fixed per building instance
- `lv(t, n)` — floor count = `target_height_metres / n` (rounds to integer)
- `h`, `w`, `d`, `x`, `y`, `z`, `seg`, `offset` — resolved values of **sibling fields in the same block**
- Standard arithmetic: `+ - * / ( )`

Cross-field refs work via **two-pass resolution**: pass 1 resolves `r1/r2/r3/lv()`, pass 2 substitutes the now-numeric peer values. So `w = h*0.5` works whether `h` is a plain number or `lv(t,3.5)`. Circular refs (w references h AND h references w) are not supported.

**Ruby**: `resolve(expr, t, r1, r2, r3, block_fields = nil)` in `MagArkido_Core.rb` — whitelist-validates the string before `eval()`.  
**JS**: `evalExpr(v, r1v, r2v, r3v, ph, fields)` in `manager.html`.

## Geometry pipeline (`create()` in Ruby)
1. Add a new group inside the target entity.
2. Resolve all block expressions (two passes).
3. Build cube geometry + detail lines (`dv1` = horizontal, `dv2` = vertical).
4. Randomly rotate 0/90/180/270°.
5. **Non-uniform scale** to exactly fit the target's bounding box on each axis independently (`width/height/depth`).
6. Erase everything in the target except the new group.

**Critical for canvas preview**: because SketchUp scales X, Y, Z independently, the ISO canvas normalises each axis by its own maximum (`x/maxX`, `y/maxY`, `z/maxZ`) to match the applied result.

## JS bridge
- JS → Ruby: `sketchup.callbackName(jsonString)` 
- Pattern data is pre-injected as `window.magarkidoPatterns` via `set_html` to avoid async timing issues.
- `UI.openpanel` inside a dialog callback must be wrapped in `UI.start_timer(0, false)`.

## ISO canvas
- Isometric projection, painter's algorithm.
- Sort order: **ascending Z primary** (lower blocks first), **descending X+Y secondary** (furthest back drawn first at same Z level).
- Three-face shading: top = 100%, right = 78%, left = 62% of base material colour.
- Detail lines drawn as thin strokes over face geometry.
- Canvas dimensions sync via `syncCanvas()` called at the top of every `drawISO()`.

## Editor features (manager.html)
- Block list with drag-to-reorder (HTML5 DnD), updates canvas live.
- Inspector with sliders; any field can toggle to `fx` expression mode via the `fx` button.
- Expression badge (`= value` green / `⚠ err` red) displayed inline for each active expression.
- ISO canvas with target-height slider (`lv` reference), Randomize and Refresh buttons.
- Undo stack (`pushHistory` / `undo`), Save, Save As New, Test (apply without saving), Delete selection.

## SketchUp install path
`~/Library/Application Support/SketchUp 2026/SketchUp/Plugins/`
