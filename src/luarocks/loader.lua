--- A module which installs a Lua package loader that is LuaRocks-aware.
-- This loader uses dependency information from the LuaRocks tree to load
-- correct versions of modules. It does this by constructing a "context"
-- table in the environment, which records which versions of packages were
-- used to load previous modules, so that the loader chooses versions
-- that are declared to be compatible with the ones loaded earlier.

-- luacheck: globals luarocks

local loaders = package.loaders or package.searchers
local require, ipairs, table, type, next, tostring, error =
      require, ipairs, table, type, next, tostring, error
local unpack = unpack or table.unpack

local loader = {}

local is_clean = not package.loaded["luarocks.core.cfg"]

-- This loader module depends only on core modules.
local cfg = require("luarocks.core.cfg")
local cfg_ok, err = cfg.init()
if cfg_ok then
   cfg.init_package_paths()
end

local path = require("luarocks.core.path")
local manif = require("luarocks.core.manif")
local vers = require("luarocks.core.vers")
local require = nil  -- luacheck: ignore 411
--------------------------------------------------------------------------------

local temporary_global = false

loader.context = {}

--- Process the dependencies of a package to determine its dependency
-- chain for loading modules.
-- @param name string: The name of an installed rock.
-- @param version string: The version of the rock, in string format
function loader.add_context(name, version)
   -- assert(type(name) == "string")
   -- assert(type(version) == "string")

   if temporary_global then
      -- The first thing a wrapper does is to call add_context.
      -- From here on, it's safe to clean the global environment.
      luarocks = nil
      temporary_global = false
   end

   local tree_manifests = manif.load_rocks_tree_manifests()
   if not tree_manifests then
      return nil
   end

   return manif.scan_dependencies(name, version, tree_manifests, loader.context)
end

--- Internal sorting function.
-- @param a table: A provider table.
-- @param b table: Another provider table.
-- @return boolean: True if the version of a is greater than that of b.
local function sort_versions(a,b)
   return a.version > b.version
end

--- Request module to be loaded through other loaders,
-- once the proper name of the module has been determined.
-- For example, in case the module "socket.core" has been requested
-- to the LuaRocks loader and it determined based on context that
-- the version 2.0.2 needs to be loaded and it is not the current
-- version, the module requested for the other loaders will be
-- "socket.core_2_0_2".
-- @param module The module name requested by the user, such as "socket.core"
-- @param name The rock name, such as "luasocket"
-- @param version The rock version, such as "2.0.2-1"
-- @param module_name The actual module name, such as "socket.core" or "socket.core_2_0_2".
-- @return table or (nil, string): The module table as returned by some other loader,
-- or nil followed by an error message if no other loader managed to load the module.
local function call_other_loaders(module, name, version, module_name)
   for _, a_loader in ipairs(loaders) do
      if a_loader ~= loader.luarocks_loader then
         local results = { a_loader(module_name) }
         if type(results[1]) == "function" then
            return unpack(results)
         end
      end
   end
   return "Failed loading module "..module.." in LuaRocks rock "..name.." "..version
end

local function add_providers(providers, entries, tree, module, filter_file_name)
   for i, entry in ipairs(entries) do
      local name, version = entry:match("^([^/]*)/(.*)$")
      local file_name = tree.manifest.repository[name][version][1].modules[module]
      if type(file_name) ~= "string" then
         error("Invalid data in manifest file for module "..tostring(module).." (invalid data for "..tostring(name).." "..tostring(version)..")")
      end
      file_name = filter_file_name(file_name, name, version, tree.tree, i)
      if loader.context[name] == version then
         return name, version, file_name
      end
      version = vers.parse_version(version)
      table.insert(providers, {name = name, version = version, module_name = file_name, tree = tree})
   end
end

--- Search for a module in the rocks trees
-- @param module string: module name (eg. "socket.core")
-- @param filter_file_name function(string, string, string, string, number):
-- a function that takes the module file name (eg "socket/core.so"), the rock name
-- (eg "luasocket"), the version (eg "2.0.2-1"), the path of the rocks tree
-- (eg "/usr/local"), and the numeric index of the matching entry, so the
-- filter function can know if the matching module was the first entry or not.
-- @return string, string, string, (string or table):
-- * name of the rock containing the module (eg. "luasocket")
-- * version of the rock (eg. "2.0.2-1")
-- * return value of filter_file_name
-- * tree of the module (string or table in `tree_manifests` format)
local function select_module(module, filter_file_name)
   --assert(type(module) == "string")
   --assert(type(filter_module_name) == "function")

   local tree_manifests = manif.load_rocks_tree_manifests()
   if not tree_manifests then
      return nil
   end

   local providers = {}
   local initmodule
   for _, tree in ipairs(tree_manifests) do
      local entries = tree.manifest.modules[module]
      if entries then
         local n, v, f = add_providers(providers, entries, tree, module, filter_file_name)
         if n then
            return n, v, f
         end
      else
         initmodule = initmodule or module .. ".init"
         entries = tree.manifest.modules[initmodule]
         if entries then
            local n, v, f = add_providers(providers, entries, tree, initmodule, filter_file_name)
            if n then
               return n, v, f
            end
         end
      end
   end

   if next(providers) then
      table.sort(providers, sort_versions)
      local first = providers[1]
      return first.name, first.version.string, first.module_name, first.tree
   end
end

--- Search for a module
-- @param module string: module name (eg. "socket.core")
-- @return string, string, string, (string or table):
-- * name of the rock containing the module (eg. "luasocket")
-- * version of the rock (eg. "2.0.2-1")
-- * name of the module (eg. "socket.core", or "socket.core_2_0_2" if file is stored versioned).
-- * tree of the module (string or table in `tree_manifests` format)
local function pick_module(module)
   return
      select_module(module, function(file_name, name, version, tree, i)
         if i > 1 then
            file_name = path.versioned_name(file_name, "", name, version)
         end
         return path.path_to_module(file_name)
      end)
end

--- Return the pathname of the file that would be loaded for a module.
-- @param module string: module name (eg. "socket.core")
-- @param where string: places to look for the module. If `where` contains
-- "l", it will search using the LuaRocks loader; if it contains "p",
-- it will look in the filesystem using package.path and package.cpath.
-- You can use both at the same time.
-- @return If successful, it will return four values.
-- * If found using the LuaRocks loader, it will return:
--   * filename of the module (eg. "/usr/local/lib/lua/5.1/socket/core.so"),
--   * rock name
--   * rock version
--   * "l" to indicate the match comes from the loader.
-- * If found scanning package.path and package.cpath, it will return:
--   * filename of the module (eg. "/usr/local/lib/lua/5.1/socket/core.so"),
--   * "path" or "cpath"
--   * nil
--   * "p" to indicate the match comes from scanning package.path and cpath.
-- If unsuccessful, nothing is returned.
function loader.which(module, where)
   where = where or "l"
   if where:match("l") then
      local rock_name, rock_version, file_name = select_module(module, path.which_i)
      if rock_name then
         local fd = io.open(file_name)
         if fd then
            fd:close()
            return file_name, rock_name, rock_version, "l"
         end
      end
   end
   if where:match("p") then
      local modpath = module:gsub("%.", "/")
      for _, v in ipairs({"path", "cpath"}) do
         for p in package[v]:gmatch("([^;]+)") do
            local file_name = p:gsub("%?", modpath)  -- luacheck: ignore 421
            local fd = io.open(file_name)
            if fd then
               fd:close()
               return file_name, v, nil, "p"
            end
         end
      end
   end
end

--- Package loader for LuaRocks support.
-- A module is searched in installed rocks that match the
-- current LuaRocks context. If module is not part of the
-- context, or if a context has not yet been set, the module
-- in the package with the highest version is used.
-- @param module string: The module name, like in plain require().
-- @return table: The module table (typically), like in plain
-- require(). See <a href="http://www.lua.org/manual/5.1/manual.html#pdf-require">require()</a>
-- in the Lua reference manual for details.
function loader.luarocks_loader(module)
   local name, version, module_name = pick_module(module)
   if not name then
      return "No LuaRocks module found for "..module
   else
      loader.add_context(name, version)
      return call_other_loaders(module, name, version, module_name)
   end
end

table.insert(loaders, 1, loader.luarocks_loader)

if is_clean then
   for modname, _ in pairs(package.loaded) do
      if modname:match("^luarocks%.") then
         package.loaded[modname] = nil
      end
   end
end

return loader
