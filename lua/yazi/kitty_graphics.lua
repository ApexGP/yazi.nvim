local M = {}

local PROBE_TIMEOUT_MS = 2000

-- Kitty graphics protocol escape sequences are APC sequences: ESC _ G ... ESC
-- backslash. Neovim's embedded terminal (libvterm) keeps the unicode
-- placeholder cells but discards the APC, so yazi.nvim has to relay the APC to
-- the host terminal.
---@param sequence string
---@return boolean
function M.is_kitty_graphics_sequence(sequence)
  return sequence:sub(1, 3) == "\27_G"
end

---@param sequence string
---@return string
function M.metadata(sequence)
  return sequence:match("^\27_G([^;]*)") or ""
end

---@param sequence string
---@return string|nil
function M.action(sequence)
  local metadata = M.metadata(sequence)
  return metadata:match("^a=([^,]+)") or metadata:match(",a=([^,]+)")
end

---Kitty graphics capability probes (`a=q`) do not draw anything. They must
---still be relayed to the host terminal so that yazi learns whether the host
---supports the protocol and shared memory image transfers.
---@param sequence string
---@return boolean
function M.is_capability_probe(sequence)
  if not M.is_kitty_graphics_sequence(sequence) then
    return false
  end
  return M.action(sequence) == "q"
end

---@param sequence string
---@return boolean
function M.is_image_payload(sequence)
  if not M.is_kitty_graphics_sequence(sequence) then
    return false
  end
  return M.action(sequence) ~= "q"
end

---The TUI strips the APC terminator from host terminal responses. yazi's
---parser expects the terminating ST sequence.
---@param response string
---@return string
function M.ensure_terminator(response)
  if response:sub(-2) == "\27\\" then
    return response
  end
  return response .. "\27\\"
end

---tmux only forwards sequences wrapped in its DCS passthrough format. The
---`allow-passthrough` option permits this wrapper; it does not forward raw
---APC sequences.
---@param data string
---@return string
function M.wrap_for_tmux(data)
  return "\27Ptmux;" .. data:gsub("\27", "\27\27") .. "\27\\"
end

---`io.stdout:write()` can interleave with the TUI's screen output, which
---splits the APC and makes the terminal discard it. `nvim_ui_send()` writes
---through the UI output stream instead.
---@param sequence string
---@param terminator string
function M.forward(sequence, terminator)
  local data = sequence .. terminator
  if vim.env.TMUX ~= nil and vim.env.TMUX ~= "" then
    data = M.wrap_for_tmux(data)
  end

  vim.api.nvim_ui_send(data)
end

---@return boolean
function M.is_outer_terminal_supported()
  local env = vim.env
  return env.KITTY_WINDOW_ID ~= nil
    or env.TERM == "xterm-kitty"
    or env.TERM == "xterm-ghostty"
    or env.TERM_PROGRAM == "ghostty"
    or env.GHOSTTY_RESOURCES_DIR ~= nil
end

local warned = false

---@param buffer integer
function M.setup(buffer)
  if vim.fn.exists("##TermRequest") ~= 1 then
    vim.notify(
      "yazi.nvim: kitty graphics forwarding requires Neovim with TermRequest APC support",
      vim.log.levels.WARN,
      { title = "yazi.nvim" }
    )
    return
  end

  if vim.api.nvim_ui_send == nil then
    vim.notify(
      "yazi.nvim: kitty graphics forwarding requires Neovim 0.12+ (nvim_ui_send)",
      vim.log.levels.WARN,
      { title = "yazi.nvim" }
    )
    return
  end

  if not M.is_outer_terminal_supported() and not warned then
    warned = true
    vim.notify(
      "yazi.nvim: `future_features.forward_kitty_graphics` is enabled, but the outer terminal does not look like kitty or ghostty. Images may not be displayed.",
      vim.log.levels.WARN,
      { title = "yazi.nvim" }
    )
  end

  local group = vim.api.nvim_create_augroup(
    "yazi_kitty_graphics_" .. buffer,
    { clear = true }
  )
  ---@type table<string, true>
  local pending_probes = {}

  -- yazi asks the host terminal whether it supports image transfers. Relay the
  -- terminal's answer back to yazi. When shared memory transfers are accepted,
  -- yazi sends only a reference to the image instead of the encoded pixels, so
  -- the image data never has to pass through Neovim's terminal emulator.
  vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(event)
      local response = (event.data and event.data.sequence)
        or vim.v.termresponse
      if
        type(response) ~= "string"
        or not M.is_kitty_graphics_sequence(response)
      then
        return
      end

      local id = M.metadata(response):match("i=(%d+)")
      if id == nil or pending_probes[id] == nil then
        return
      end
      pending_probes[id] = nil

      if not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      local channel = vim.bo[buffer].channel
      if type(channel) == "number" and channel > 0 then
        -- The yazi process may have exited between the probe and the response.
        pcall(vim.api.nvim_chan_send, channel, M.ensure_terminator(response))
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buffer,
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })

  vim.api.nvim_create_autocmd("TermRequest", {
    group = group,
    buffer = buffer,
    callback = function(event)
      local sequence = event.data.sequence

      if M.is_capability_probe(sequence) then
        local id = M.metadata(sequence):match("i=(%d+)")
        if id ~= nil then
          pending_probes[id] = true
          vim.defer_fn(function()
            pending_probes[id] = nil
          end, PROBE_TIMEOUT_MS)
        end
        M.forward(sequence, event.data.terminator)
        return
      end

      if not M.is_image_payload(sequence) then
        return
      end

      M.forward(sequence, event.data.terminator)
    end,
  })
end

return M
