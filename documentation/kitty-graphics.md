# Kitty graphics (experimental)

> [!WARNING]
>
> This feature depends on a yazi change that is not released yet. It is
> opt-in and may change.

Neovim's built-in terminal emulator (libvterm) does not implement any image
protocol. When yazi runs inside `:terminal`, it detects libvterm, selects the
chafa fallback, and the preview pane shows ASCII art instead of the real image.

yazi.nvim can bridge the kitty graphics protocol (KGP) from yazi to the host
terminal. yazi still owns the preview logic; yazi.nvim only forwards the image
data.

## Requirements

- kitty >= 0.28.0 or Ghostty. Both support KGP with unicode placeholders.
- yazi with the embedded-terminal fix. Without it, yazi reports libvterm via
  XTVERSION and overrides the kitty brand, so the feature does nothing.
- Neovim 0.12+ (`TermRequest` support for APC sequences and `nvim_ui_send()`).
  The feature is tested with Neovim 0.12.6.
- A TUI session. GUI clients and remote UI clients do not share Neovim's
  stdout, so the forwarded sequences cannot reach the host terminal.

## Configuration

```lua
---@type YaziConfig
opts = {
  future_features = {
    forward_kitty_graphics = true,
  },
}
```

yazi.nvim sets `KITTY_WINDOW_ID` for the yazi process, which makes yazi select
the KGP adapter. It then listens for `TermRequest` events on the yazi terminal
buffer and writes the image APC sequences to Neovim's stdout.

## tmux

If Neovim runs inside tmux, tmux must pass the graphics sequences through:

```sh
set -g allow-passthrough on
set -ga update-environment TERM
set -ga update-environment TERM_PROGRAM
```

Restart tmux after changing the configuration. Without passthrough, the
placeholder characters still reach the host terminal, but the image data does
not, so nothing is displayed.

## How it works

```
yazi -> KGP APC (image data) + U+10EEEE unicode placeholders
     -> Neovim terminal (libvterm keeps the placeholder cells, drops the APC)
     -> TermRequest autocmd in yazi.nvim
     -> io.stdout (the outer terminal)
     -> kitty composes the image over the placeholder cells
```

Unicode placeholders are important here: unlike cursor-positioned image
protocols, they are anchored to the terminal cells, so the image follows
Neovim's window layout, scrolling, and redraws.

yazi's capability probe (`a=q`) is not forwarded. It would only make the host
terminal reply with a response that cannot be delivered back to yazi. Image
transmission and deletion commands are forwarded.

## Limitations

- Only KGP is supported. sixel and the iTerm2 inline image protocol are
  cursor-positioned and do not survive Neovim's cell-based redraws.
- Only PNG/JPEG/etc. formats that yazi's KGP adapter can decode are shown. PDF,
  video, and other previewers that yazi renders through external tools keep
  their normal behavior.
- With `open_multiple_tabs` or multiple yazi instances, images use yazi's
  process id as the image id. This is the same behaviour as running yazi
  directly.
- Image position and size are controlled by yazi's `[preview]` settings
  (`max_width`, `max_height`, `image_filter`, etc.). Run `ya cache clear` after
  changing them.

## Troubleshooting

- Run `:checkhealth yazi`. It reports whether the outer terminal looks
  compatible when the feature is enabled.
- Run `ya env` in the same terminal. Outside Neovim, `Adapter.Drivers.matches`
  should be `Kgp`. Inside Neovim, the brand fix is what allows KGP to be
  selected despite libvterm.
- Check `:messages` for a warning from yazi.nvim about an unsupported outer
  terminal.
- If images appear as placeholder glyphs, the image APC did not reach the host
  terminal. Check tmux passthrough and whether Neovim's stdout is the terminal
  you are looking at.

## Why not Überzug++ or chafa?

- Überzug++ uses an X11/Wayland overlay. It is not available on macOS without
  X11 and needs a manually tuned offset for the floating window.
- chafa is the default fallback. It renders Unicode block art, not the image.
