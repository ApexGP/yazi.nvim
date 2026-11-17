local assert = require("luassert")
local kitty_graphics = require("yazi.kitty_graphics")

describe("kitty graphics forwarding", function()
  describe("is_kitty_graphics_sequence", function()
    it("recognizes kitty graphics APC sequences", function()
      assert.is_true(
        kitty_graphics.is_kitty_graphics_sequence("\27_Ga=T;AAAA\27\\")
      )
    end)

    it("ignores other terminal requests", function()
      assert.is_false(
        kitty_graphics.is_kitty_graphics_sequence("\27]7;file:///tmp\27\\")
      )
      assert.is_false(
        kitty_graphics.is_kitty_graphics_sequence("\27P>|kitty(0.40)\27\\")
      )
    end)
  end)

  describe("is_image_payload", function()
    it("forwards image data and delete commands", function()
      assert.is_true(
        kitty_graphics.is_image_payload("\27_Gq=2,a=T,i=7;AAAA\27\\")
      )
      assert.is_true(kitty_graphics.is_image_payload("\27_Ga=d,d=A\27\\"))
    end)

    it("skips capability probes", function()
      assert.is_false(
        kitty_graphics.is_image_payload(
          "\27_Gi=278941603,a=q,s=1,v=1,t=d,f=24;AAAA\27\\"
        )
      )
    end)
  end)

  describe("is_capability_probe", function()
    it("recognizes capability probes", function()
      assert.is_true(
        kitty_graphics.is_capability_probe(
          "\27_Gi=278941603,s=1,v=1,a=q,t=d,f=24;AAAA\27\\"
        )
      )
      assert.is_true(
        kitty_graphics.is_capability_probe(
          "\27_Gi=916472805,s=1,v=1,a=q,t=s,f=24,S=3;AAAA\27\\"
        )
      )
    end)

    it("does not match image payloads", function()
      assert.is_false(
        kitty_graphics.is_capability_probe("\27_Gq=2,a=T,i=7;AAAA\27\\")
      )
    end)
  end)

  describe("ensure_terminator", function()
    it("adds the missing ST terminator", function()
      assert.are.same(
        "\27_Gi=916472805;OK\27\\",
        kitty_graphics.ensure_terminator("\27_Gi=916472805;OK")
      )
    end)

    it("does not duplicate an existing terminator", function()
      assert.are.same(
        "\27_Gi=916472805;OK\27\\",
        kitty_graphics.ensure_terminator("\27_Gi=916472805;OK\27\\")
      )
    end)
  end)

  describe("setup", function()
    local buffer
    local channel

    before_each(function()
      buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buffer)
      vim.fn.termopen({ "cat" })
      channel = vim.bo[buffer].channel
    end)

    after_each(function()
      if channel and channel > 0 then
        pcall(vim.fn.jobstop, channel)
      end
      if vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
    end)

    it("relays capability probe responses to yazi", function()
      local original_ui_send = vim.api.nvim_ui_send
      local original_chan_send = vim.api.nvim_chan_send
      local original_tmux = vim.env.TMUX
      local forwarded = {}
      local replies = {}
      vim.env.TMUX = nil
      vim.api.nvim_ui_send = function(data)
        forwarded[#forwarded + 1] = data
      end
      vim.api.nvim_chan_send = function(_, data)
        replies[#replies + 1] = data
      end

      local ok, error_message = pcall(function()
        kitty_graphics.setup(buffer)

        vim.api.nvim_exec_autocmds("TermRequest", {
          buffer = buffer,
          data = {
            sequence = "\27_Gi=916472805,s=1,v=1,a=q,t=s,f=24,S=3;AAAA",
            terminator = "\27\\",
            cursor = { 0, 0 },
          },
        })

        vim.api.nvim_exec_autocmds("TermResponse", {
          data = { sequence = "\27_Gi=916472805;OK" },
        })

        vim.api.nvim_exec_autocmds("TermResponse", {
          data = { sequence = "\27_Gi=999;OK" },
        })
      end)

      vim.api.nvim_ui_send = original_ui_send
      vim.api.nvim_chan_send = original_chan_send
      vim.env.TMUX = original_tmux

      assert(ok, error_message)
      assert.are.same(
        { "\27_Gi=916472805,s=1,v=1,a=q,t=s,f=24,S=3;AAAA\27\\" },
        forwarded
      )
      assert.are.same({ "\27_Gi=916472805;OK\27\\" }, replies)
    end)

    it("resolves the terminal channel after setup", function()
      local early_buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(early_buffer)
      local early_channel
      local original_ui_send = vim.api.nvim_ui_send
      local original_chan_send = vim.api.nvim_chan_send
      local replies = {}
      vim.api.nvim_ui_send = function() end
      vim.api.nvim_chan_send = function(_, data)
        replies[#replies + 1] = data
      end

      local ok, error_message = pcall(function()
        -- setup() runs before the terminal process exists, so the channel
        -- must be resolved lazily when the response arrives.
        kitty_graphics.setup(early_buffer)
        vim.fn.termopen({ "cat" })
        early_channel = vim.bo[early_buffer].channel

        vim.api.nvim_exec_autocmds("TermRequest", {
          buffer = early_buffer,
          data = {
            sequence = "\27_Gi=916472805,s=1,v=1,a=q,t=s,f=24,S=3;AAAA",
            terminator = "\27\\",
            cursor = { 0, 0 },
          },
        })
        vim.api.nvim_exec_autocmds("TermResponse", {
          data = { sequence = "\27_Gi=916472805;OK" },
        })
      end)

      vim.api.nvim_ui_send = original_ui_send
      vim.api.nvim_chan_send = original_chan_send

      assert(ok, error_message)
      assert.are.same({ "\27_Gi=916472805;OK\27\\" }, replies)
      if early_channel and early_channel > 0 then
        pcall(vim.fn.jobstop, early_channel)
      end
      if vim.api.nvim_buf_is_valid(early_buffer) then
        vim.api.nvim_buf_delete(early_buffer, { force = true })
      end
    end)

    it("ignores non-probe responses", function()
      local original_ui_send = vim.api.nvim_ui_send
      local original_chan_send = vim.api.nvim_chan_send
      local replies = {}
      vim.api.nvim_ui_send = function() end
      vim.api.nvim_chan_send = function(_, data)
        replies[#replies + 1] = data
      end

      local ok, error_message = pcall(function()
        kitty_graphics.setup(buffer)
        vim.api.nvim_exec_autocmds("TermResponse", {
          data = { sequence = "\27_Gi=916472805;OK" },
        })
      end)

      vim.api.nvim_ui_send = original_ui_send
      vim.api.nvim_chan_send = original_chan_send

      assert(ok, error_message)
      assert.are.same({}, replies)
    end)
  end)

  describe("wrap_for_tmux", function()
    it("wraps the sequence and doubles every escape", function()
      assert.are.same(
        "\27Ptmux;\27\27_Ga=T;AAAA\27\27\\\27\\",
        kitty_graphics.wrap_for_tmux("\27_Ga=T;AAAA\27\\")
      )
    end)
  end)

  describe("forward", function()
    it(
      "writes the sequence and its terminator to the UI output stream",
      function()
        local original_ui_send = vim.api.nvim_ui_send
        local original_tmux = vim.env.TMUX
        vim.env.TMUX = nil
        local written = {}
        vim.api.nvim_ui_send = function(data)
          written[#written + 1] = data
        end

        local ok, error_message =
          pcall(kitty_graphics.forward, "\27_Ga=T;AAAA", "\27\\")
        vim.api.nvim_ui_send = original_ui_send
        vim.env.TMUX = original_tmux

        assert(ok, error_message)
        assert.are.same({ "\27_Ga=T;AAAA\27\\" }, written)
      end
    )

    it("wraps sequences when running inside tmux", function()
      local original_ui_send = vim.api.nvim_ui_send
      local original_tmux = vim.env.TMUX
      vim.env.TMUX = "/tmp/tmux-test"
      local written = {}
      vim.api.nvim_ui_send = function(data)
        written[#written + 1] = data
      end

      local ok, error_message =
        pcall(kitty_graphics.forward, "\27_Ga=T;AAAA", "\27\\")
      vim.api.nvim_ui_send = original_ui_send
      vim.env.TMUX = original_tmux

      assert(ok, error_message)
      assert.are.same({ "\27Ptmux;\27\27_Ga=T;AAAA\27\27\\\27\\" }, written)
    end)
  end)

  it("is disabled by default", function()
    local config = require("yazi.config").default()
    assert.is_false(config.future_features.forward_kitty_graphics)
  end)
end)
