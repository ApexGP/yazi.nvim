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

  describe("forward", function()
    it("writes the sequence and its terminator to stdout", function()
      local original_stdout = io.stdout
      local written = {}
      io.stdout = {
        write = function(_, ...)
          for _, value in ipairs({ ... }) do
            written[#written + 1] = value
          end
          return true
        end,
        flush = function() end,
      }

      local ok, error_message =
        pcall(kitty_graphics.forward, "\27_Ga=T;AAAA", "\27\\")
      io.stdout = original_stdout

      assert(ok, error_message)
      assert.are.same({ "\27_Ga=T;AAAA", "\27\\" }, written)
    end)
  end)

  it("is disabled by default", function()
    local config = require("yazi.config").default()
    assert.is_false(config.future_features.forward_kitty_graphics)
  end)
end)
