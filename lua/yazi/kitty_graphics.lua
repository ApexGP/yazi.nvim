local M = {}

-- Kitty graphics protocol escape sequences are APC sequences: ESC _ G ... ESC
-- backslash. Neovim's embedded terminal (libvterm) keeps the unicode
-- placeholder cells but discards the APC, so yazi.nvim has to relay the APC to
-- the host terminal.
---@param sequence string
---@return boolean
function M.is_kitty_graphics_sequence(sequence)
  return sequence:sub(1, 3) == "\27_G"
end

---Yazi's capability probe (`a=q`) does not draw anything. Relaying it would
---make the host terminal reply with a response that cannot be delivered back
---to yazi, so only forward actual image payloads.
---@param sequence string
---@return boolean
function M.is_image_payload(sequence)
  if not M.is_kitty_graphics_sequence(sequence) then
    return false
  end

  local meta = sequence:match("^\27_G([^;]*)") or ""
  local action = meta:match("^a=([^,]+)") or meta:match(",a=([^,]+)")
  return action ~= "q"
end

---@param sequence string
---@param terminator string
function M.forward(sequence, terminator)
  local stdout = io.stdout
  if stdout == nil then
    return
  end

  stdout:write(sequence, terminator)
  stdout:flush()
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

  if not M.is_outer_terminal_supported() and not warned then
    warned = true
    vim.notify(
      "yazi.nvim: `future_features.forward_kitty_graphics` is enabled, but the outer terminal does not look like kitty or ghostty. Images may not be displayed.",
      vim.log.levels.WARN,
      { title = "yazi.nvim" }
    )
  end

  vim.api.nvim_create_autocmd("TermRequest", {
    buffer = buffer,
    callback = function(event)
      local sequence = event.data.sequence
      if not M.is_image_payload(sequence) then
        return
      end

      M.forward(sequence, event.data.terminator)
    end,
  })
end

return M
