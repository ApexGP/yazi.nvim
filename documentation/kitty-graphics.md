# Kitty graphics (experimental)

> [!WARNING]
>
> This feature depends on a yazi change that is not released yet. It is opt-in and may change.

Neovim's built-in terminal emulator (libvterm) does not implement any image protocol. When yazi runs inside `:terminal`,
it detects libvterm, selects the chafa fallback, and the preview pane shows ASCII art instead of the real image.

yazi.nvim can bridge the kitty graphics protocol (KGP) from yazi to the host terminal. yazi still owns the preview
logic; yazi.nvim only forwards the image data.

## Requirements

- kitty >= 0.28.0 or Ghostty >= 1.4. Both support KGP with unicode placeholders and shared memory image transfers.
- yazi with the embedded-terminal fix. Without it, yazi reports libvterm via XTVERSION and overrides the kitty brand, so
  the feature does nothing.
- Neovim 0.12+ (`TermRequest` support for APC sequences, `TermResponse` support for APC query responses, and
  `nvim_ui_send()`). The feature is tested with Neovim 0.12.6.
- A TUI session. GUI clients and remote UI clients do not share Neovim's stdout, so the forwarded sequences cannot reach
  the host terminal.
- The host terminal must share the filesystem with yazi, because the image pixels are transferred through POSIX shared
  memory. This is always true for a local terminal. Over SSH the shared memory probe fails and yazi falls back to inline
  base64 transfers.

## Configuration

```lua
---@type YaziConfig
opts = {
  future_features = {
    forward_kitty_graphics = true,
  },
}
```

yazi.nvim sets `KITTY_WINDOW_ID` for the yazi process, which makes yazi select the KGP adapter. It then listens for
`TermRequest` events on the yazi terminal buffer and writes the image APC sequences to the host terminal through
Neovim's UI output stream.

It also relays yazi's KGP capability probes (`a=q`) to the host terminal and sends the host's responses back to yazi.
When the host accepts shared memory transfers, yazi sends only a reference to the image instead of the encoded pixels.

## tmux

If Neovim runs inside tmux, tmux must pass the graphics sequences through:

```sh
set -g allow-passthrough on
set -ga update-environment TERM
set -ga update-environment TERM_PROGRAM
```

Restart tmux after changing the configuration. yazi.nvim wraps the forwarded APCs in tmux's DCS passthrough format
(`ESC Ptmux; ... ESC\`) automatically; `allow-passthrough` only permits that wrapper and does not forward raw APC
sequences. Without passthrough, the placeholder characters still reach the host terminal, but the image data does not,
so nothing is displayed.

## How it works

```text
yazi -> KGP capability probes -> Neovim -> yazi.nvim -> outer terminal
     <- KGP probe responses    <- Neovim <- yazi.nvim <- outer terminal

yazi -> KGP APC (shared memory reference) + U+10EEEE unicode placeholders
     -> Neovim terminal (libvterm keeps the placeholder cells, drops the APC)
     -> TermRequest autocmd in yazi.nvim
     -> nvim_ui_send (the outer terminal)
     -> the outer terminal reads the shared memory object and composes the
        image over the placeholder cells
```

Unicode placeholders are important here: unlike cursor-positioned image protocols, they are anchored to the terminal
cells, so the image follows Neovim's window layout, scrolling, and redraws.

The shared memory transfer is not just an optimization. Large previews such as a rendered PDF page or a video frame are
megabytes of encoded data. Sending them through the embedded terminal is slow, and Neovim 0.12.6 drops an APC sequence
if its `ESC \` terminator happens to straddle two reads from the terminal's pty, which corrupts the image. With shared
memory, the pty only carries a short reference to the image.

If the shared memory probe fails, yazi falls back to inline base64 transmission through the pty. Images still work, but
very large previews may lose a block due to the Neovim issue above.

## Limitations

- Only KGP is supported. sixel and the iTerm2 inline image protocol are cursor-positioned and do not survive Neovim's
  cell-based redraws.
- Previewers that yazi renders through external tools (PDF pages, video frames, SVG, and similar) work as long as they
  finalize to an image that yazi's KGP adapter can transfer. A tool that is missing from `PATH` still shows yazi's
  normal error message.
- With `open_multiple_tabs` or multiple yazi instances, images use yazi's process id as the image id. This is the same
  behaviour as running yazi directly.
- Image position and size are controlled by yazi's `[preview]` settings (`max_width`, `max_height`, `image_filter`,
  etc.). Run `ya cache clear` after changing them.
- Shared memory transfers require the host terminal and yazi to run on the same machine. Remote terminals (for example
  over SSH) fall back to inline base64 transfers.

## Troubleshooting

- Run `:checkhealth yazi`. It reports whether the outer terminal looks compatible when the feature is enabled.
- Run `ya env` in the same terminal. Outside Neovim, `Adapter.Drivers.matches` should be `Kgp`. Inside Neovim, the brand
  fix is what allows KGP to be selected despite libvterm.
- Check `:messages` for a warning from yazi.nvim about an unsupported outer terminal.
- If images appear as placeholder glyphs, the image APC did not reach the host terminal. Check tmux passthrough and
  whether Neovim's stdout is the terminal you are looking at.

## Why not Überzug++ or chafa?

- Überzug++ uses an X11/Wayland overlay. It is not available on macOS without X11 and needs a manually tuned offset for
  the floating window.
- chafa is the default fallback. It renders Unicode block art, not the image.
