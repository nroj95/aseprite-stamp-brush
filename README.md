# Stamp Brush

A clone-stamp brush extension for [Aseprite](https://www.aseprite.org/) — select a source area and paint with it like a stamp. Includes tiled canvas support, soft brushes, pan/zoom, selection masking, local undo/redo, transparent cloning, and RGB, grayscale, and indexed-color support.

<p align="center">
<img src="https://img.shields.io/badge/Aseprite-1.3+-brightgreen" alt="Aseprite 1.3+">
<img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
<img src="https://img.shields.io/badge/version-1.0.0-orange" alt="Version 1.0.0">
</p>

https://github.com/user-attachments/assets/1e630c10-5291-4cc8-8258-739a48feb691

## 📜 Table of contents

- [Features](#-features)
- [How to install](#-how-to-install)
- [How to use](#-how-to-use)
- [Controls](#-controls)
- [FAQ](#-faq)

## 🎯 Features

- **Clone-stamp brush** — sample from any part of the sprite canvas and paint it elsewhere.
- **Soft brush** — adjustable radius (1–64), softness, opacity, and smooth stamp interpolation.
- **RGB, grayscale, and indexed color** — cloning and previews work across all three supported Aseprite image modes.
- **Transparent cloning** — transparent source pixels can erase destination pixels correctly.
- **Alpha-aware blending** — opacity behaves correctly with partially transparent and fully transparent source pixels.
- **Tiled canvas** — display and work with no tiling, horizontal tiling, vertical tiling, or both axes.
- **Correct edge behavior** — untiled painting clips at sprite boundaries; enabled tiled axes wrap correctly.
- **Pan and zoom** — mouse wheel zoom, Space + left drag or middle drag to pan, plus horizontal and vertical wheel panning.
- **Selection masking** — painting is restricted to the active selection when one exists.
- **Dynamic preview** — preview shows the actual resulting pixels before painting, including grayscale, indexed color, and transparency.
- **High-contrast markers** — source and destination rings use a dark outer stroke and light inner stroke so they remain visible over varied artwork.
- **Source/destination alignment guide** — after choosing a source, a two-tone line connects it to the moving destination ring until the first destination is chosen, making horizontal and vertical alignment easy to see.
- **Local undo/redo** — undo and redo clone-stamp strokes before applying them to the document.
- **No-op stroke detection** — strokes that do not change any pixels are not added to the local history.
- **Safe Apply** — all session changes are committed in one native Aseprite transaction so the final Apply can be undone/redone normally in Aseprite.
- **Auto-expanding cel** — painting outside the original cel bounds expands the resulting cel to contain the new pixels.
- **Session validation** — Apply is rejected safely if the original sprite, cel, layer, canvas, or image changed underneath the session.
- **Continue Editing** — closing after making changes offers Apply, Discard, or Continue Editing without losing the current clone-stamp session.
- **Full-window workspace** — each new Clone Stamp session opens to the size of the Aseprite window.
- **Nynorsk localization** — automatically loads `locale/nn.lua` when Aseprite is using the `nn` language. English remains the fallback.

## 💽 How to install

1. Download the `.aseprite-extension` file from the [Releases](https://github.com/nklbdev/aseprite-stamp-brush/releases) page.
2. Double-click the file, or install via _Edit > Preferences > Extensions > Add Extension_.
3. Restart Aseprite if necessary.
4. The **Clone Stamp** command appears in the _Edit_ menu and includes **K** as its default shortcut.

The shortcut can be changed through _Edit > Keyboard Shortcuts_.

If Aseprite is using Nynorsk (`nn`), the bundled Nynorsk translation is loaded automatically. Other languages currently fall back to English.

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
9. Click **Apply** to commit immediately, or close with **Esc**, **K**, or the window close button to choose **Apply**, **Discard**, or **Continue Editing**.

## 🎮 Controls

### Mouse controls

| Action | Control |
|---|---|
| Set source point | Left click when no source exists, or Right click at any time |
| Paint | Left click and drag |
| Cancel current stroke | Right click while drawing |
| Pan | Middle drag |
| Pan | Space + left drag |
| Zoom | Mouse wheel |
| Change brush radius | Ctrl + mouse wheel |
| Pan horizontally | Shift + mouse wheel |
| Pan vertically | Alt + mouse wheel |

### Keyboard controls

| Action | Shortcut |
|---|---|
| Open Clone Stamp | K |
| Close Clone Stamp | K while the canvas has keyboard focus |
| Close / show Apply confirmation | Esc |
| Undo clone-stamp stroke | Ctrl+Z (Cmd+Z on macOS) |
| Redo clone-stamp stroke | Ctrl+Shift+Z or Ctrl+Y (Cmd+Shift+Z or Cmd+Y on macOS) |

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

### Can the Nynorsk translation be edited separately?

Yes. The translation is stored in:

`locale/nn.lua`

Only the translated strings need to be edited. The keys on the left side should remain unchanged. The extension automatically loads the file when Aseprite's language is `nn`.
