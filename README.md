# Stamp Brush

Stamp Brush is a clone-stamp and soft-eraser extension for [Aseprite](https://www.aseprite.org/). Sample from another part of a cel and paint with it, or switch the same soft brush into eraser-only mode. It includes tiled canvas support, pan/zoom, selection masking, local undo/redo, transparent cloning, and RGB, grayscale, and indexed-color support.

<p align="center">
<img src="https://img.shields.io/badge/Aseprite-1.3+-brightgreen" alt="Aseprite 1.3+">
<img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
<img src="https://img.shields.io/badge/version-1.0.0-orange" alt="Version 1.0.0">
</p>

## 📜 Table of contents

- [Controls](#-controls)
- [Features](#-features)
- [How to install](#-how-to-install)
- [How to use](#-how-to-use)
- [FAQ](#-faq)
- [Credits](#-credits)

## 🎮 Controls

### Mouse controls

| Action | Control |
|---|---|
| Set source point | Left click when no source exists, or Right click at any time |
| Paint / erase | Left click and drag |
| Toggle clone / eraser mode | Click **Eraser Only** or **Clone Stamp** in the footer |
| Compare before / after | Click **Before** to view the untouched session image; click **After** to return |
| Cancel current stroke | Right click while drawing |
| Pan | Middle drag |
| Pan | Space + left drag |
| Zoom | Mouse wheel |
| Change brush radius | Ctrl + mouse wheel (outside temporary magnifier mode) |
| Adjust temporary magnifier zoom | Mouse wheel while holding C |
| Pan horizontally | Shift + mouse wheel |
| Pan vertically | Alt + mouse wheel |

### Keyboard controls

| Action | Shortcut |
|---|---|
| Open Clone Stamp | K |
| Close Clone Stamp | K while the canvas has keyboard focus |
| Close / show Apply confirmation | Esc |
| Temporary magnifier | Hold C; release C to restore the previous view |
| Undo clone-stamp stroke | Ctrl+Z (Cmd+Z on macOS) |
| Redo clone-stamp stroke | Ctrl+Shift+Z or Ctrl+Y (Cmd+Shift+Z or Cmd+Y on macOS) |

## 🎯 Features

- **Clone-stamp brush** — sample from any part of the sprite canvas and paint it elsewhere.
- **Soft brush** — adjustable radius (1–64), softness, opacity, and smooth stamp interpolation.
- **Eraser-only mode** — switch the same brush engine into soft erasing without choosing a clone source.
- **RGB, grayscale, and indexed color** — cloning and previews work across all three supported Aseprite image modes.
- **Transparent cloning** — transparent source pixels can erase destination pixels correctly.
- **Alpha-aware blending** — opacity behaves correctly with partially transparent and fully transparent source pixels.
- **Tiled canvas** — display and work with no tiling, horizontal tiling, vertical tiling, or both axes.
- **Correct edge behavior** — untiled painting clips at sprite boundaries; enabled tiled axes wrap correctly.
- **Pan and zoom** — mouse wheel zoom, Space + left drag or middle drag to pan, plus horizontal and vertical wheel panning.
- **Temporary magnifier** — hold C for an instant 4× detail view; wheel zoom while held is temporary, and releasing C restores the exact previous zoom and pan.
- **Live pixel status** — the footer shows hovered color channels, hex, alpha, and sprite X/Y coordinates, including wrapped coordinates on tiled axes.
- **Selection masking** — painting is restricted to the active selection when one exists.
- **Dynamic preview** — preview shows the actual resulting pixels before painting, including grayscale, indexed color, and transparency.
- **Distinct source/destination markers** — both rings use a dark outer stroke; the source keeps a light-gray inner stroke while the destination uses warm gold.
- **Source/destination alignment guide** — after choosing a source, a two-tone line connects it to the moving destination ring until the first destination is chosen. Its inner stroke turns green when the source and destination are exactly horizontally or vertically aligned.
- **Local undo/redo** — undo and redo clone-stamp strokes before applying them to the document.
- **Before/after comparison** — switch between the untouched session image and the current edited result without changing either state. Before view remains available for pan, zoom, magnification, and pixel inspection while editing actions are blocked.
- **Instant Reset** — jump back to the session's starting image in one click while keeping the full redo history available.
- **No-op stroke detection** — strokes that do not change any pixels are not added to the local history.
- **Safe Apply** — all session changes are committed in one native Aseprite transaction so the final Apply can be undone/redone normally in Aseprite.
- **Auto-expanding cel** — painting outside the original cel bounds expands the resulting cel to contain the new pixels.
- **Session validation** — Apply is rejected safely if the original sprite, cel, layer, canvas, or image changed underneath the session.
- **Continue Editing** — closing after making changes offers Apply, Discard, or Continue Editing without losing the current clone-stamp session.
- **Full-window workspace** — each new Clone Stamp session opens to the size of the Aseprite window.
- **Translation support** — locale files can override the built-in English interface, with `locale/template.lua` as the canonical translation template and a complete Nynorsk example in `locale/examples/nn.lua`.

## 💽 How to install

1. Download the `.aseprite-extension` file from the [Releases](https://github.com/nroj95/aseprite-stamp-brush/releases) page.
2. Double-click the file, or install via _Edit > Preferences > Extensions > Add Extension_.
3. Restart Aseprite if necessary.
4. The **Clone Stamp** command appears in the _Edit_ menu and includes **K** as its default shortcut.

The shortcut can be changed through _Edit > Keyboard Shortcuts_.

English is built in as the fallback language. Additional translations can be added by copying `locale/template.lua` to a file matching Aseprite's language code.

Alternatively, clone this repository and copy the folder to your Aseprite extensions directory:

- **macOS**: `~/Library/Application Support/Aseprite/extensions/`
- **Windows**: `%AppData%/Aseprite/extensions/`
- **Linux**: `~/.config/aseprite/extensions/`

## 👷 How to use

1. Open an image in Aseprite and select the cel you want to modify.
2. _(Optional)_ Make a selection if you only want to paint inside a specific area.
3. Press **K**, or run _Edit > Clone Stamp_.
4. **Left-click** when no source exists yet, or **Right-click** at any time, to choose the source point.
5. Move the destination ring into position. A temporary line connects it to the source to help with horizontal and vertical alignment.
6. **Left-click and drag** to lock the source-to-destination offset and paint with the clone stamp.
7. **Right-click** again whenever you want to choose a new source point.
8. Adjust **Tiled Mode**, **Radius**, **Opacity**, and **Softness** as needed.
9. Click **Eraser Only** in the footer whenever you want the brush to erase instead of clone. The button changes to **Clone Stamp** while eraser mode is active.
10. Click **Before** to compare against the untouched session image. Click **After** to return to the current edited result.
11. Click **Reset** at the bottom-right to jump back to the session start without discarding redo history, or click **Apply** at the bottom-left to commit immediately.
12. Close with **Esc**, **K**, or the window close button to choose **Apply**, **Discard**, or **Continue Editing**.

## ❓ FAQ

### Can I paint outside the original cel?

Yes. The working image covers the full sprite canvas, and Apply expands the cel to include painted pixels outside its original bounds.

Tiled Mode controls wrapping at the **sprite canvas edges**, not whether the original cel is allowed to grow.

### What do the Tiled Mode values mean?

- `0` — no tiling
- `1` — horizontal / X axis
- `2` — vertical / Y axis
- `3` — both axes

The default is `0`.

### Why does K sometimes stop closing the dialog after I use a slider?

Aseprite's slider widget can retain keyboard focus. The custom canvas then does not receive the `K` key event.

Click the canvas to restore its keyboard focus, or use **Esc**, which remains the reliable close key.

This is a limitation of the current Aseprite Dialog focus model, not a loss of clone-stamp state.

### Why does Clone Stamp open almost full screen?

This is intentional. A new session opens using the current Aseprite window dimensions to provide as much editing space as possible.

If you choose **Continue Editing**, the current dialog bounds are preserved for that session.

### How can I add a translation?

Copy:

`locale/template.lua`

Rename the copy to match Aseprite's language code, such as `de.lua`, `nb.lua`, or `pt-br.lua`, then translate the quoted text on the right side.

Keep the keys on the left unchanged, and preserve format placeholders such as `%d`. Strings omitted from a translation file automatically fall back to English.

A complete Nynorsk example is also available at `locale/examples/nn.lua`. It is provided as a reference and is not loaded automatically from the `examples` directory.

For regional language codes, Stamp Brush loads the base language first and then applies regional overrides. For example, `pt-br` can inherit from `locale/pt.lua` and override individual strings in `locale/pt-br.lua`.

## 💛 Credits

This project is based on the original [Aseprite Stamp Brush](https://github.com/nklbdev/aseprite-stamp-brush) by [nklbdev](https://github.com/nklbdev).

The original project provided the foundation for Stamp Brush. This project is now independently maintained and substantially expands that foundation with changes to the editing engine, correctness, controls, UI, workflow, localization, and additional tools.

The original MIT copyright and license notice are preserved in [`LICENSE`](LICENSE).
