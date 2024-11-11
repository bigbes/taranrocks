local test_env = require("spec.util.test_env")
local lfs = require("lfs")
local run = test_env.run

test_env.unload_luarocks()

describe("LuaRocks command line #integration", function()

   setup(function()
      test_env.setup_specs()
   end)

   describe("--version", function()
      it("returns the LuaRocks version", function()
         local output = run.luarocks("--version")
         assert.match("LuaRocks main command-line interface", output, 1, true)
      end)

      it("runs if Lua detection fails", function()
         test_env.run_in_tmp(function(tmpdir)
            test_env.write_file("bad_config.lua", [[
               variables = {
                  LUA_DIR = "/bad/lua/dir",
               }
            ]], finally)
            local env = {
               LUAROCKS_CONFIG = "bad_config.lua"
            }
            local output = run.luarocks("--version", env)
            assert.match("LuaRocks main command-line interface", output, 1, true)
         end, finally)
      end)
   end)

   describe("--lua-dir", function()
      it("fails if given an invalid path", function()
         local output = run.luarocks("--lua-dir=/bad/lua/path")
         assert.match("Lua interpreter not found at /bad/lua/path", output, 1, true)
      end)

      it("fails if given a valid path without Lua", function()
         local output = run.luarocks("--lua-dir=.")
         assert.match("Lua interpreter not found at .", output, 1, true)
      end)

      it("passes if given a valid path with Lua", function()
         assert.truthy(run.luarocks("--lua-dir=" .. test_env.testing_paths.luadir))
      end)

      it("passes if given a quoted path with Lua", function()
         assert.truthy(run.luarocks("--lua-dir '" .. test_env.testing_paths.luadir .. "'"))
      end)
   end)

   describe("--lua-version", function()
      it("fails if given something that is not a number", function()
         local output = run.luarocks("--lua-version=bozo")
         assert.match("malformed", output, 1, true)
      end)
   end)
end)
