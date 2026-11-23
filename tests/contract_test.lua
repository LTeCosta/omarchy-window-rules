-- Contract tests for Hyprland API stubs and examples/hyprland.lua.

local H = dofile("tests/lua_helpers.lua")
local json = dofile("hypr/json.lua")
local loader = dofile("hypr/window-rules.lua")

local STUBS_PATH = "/usr/share/hypr/stubs/hl.meta.lua"

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local f, err = io.open(path, "wb")
  H.assert_true(f ~= nil, "failed to write " .. path .. ": " .. tostring(err))
  f:write(content)
  f:close()
end

local function parse_stub_classes(text)
  local classes = {}
  local current = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local cls = line:match("^%-%-%-@class%s+([%w_%.]+)")
    if cls then
      current = classes[cls] or {}
      classes[cls] = current
    else
      local field, ftype = line:match("^%-%-%-@field%s+([%w_]+)%s+(.*)$")
      if field and current then
        current[field] = ftype
      elseif not line:match("^%-%-%-") and line:match("%S") then
        current = nil
      end
    end
  end
  return classes
end

local function stub_has_hl_path(classes, path)
  local rest = path:match("^hl%.(.+)$")
  if not rest then
    return false
  end
  local cls_name = "HL.API"
  local segments = {}
  for seg in rest:gmatch("[^%.]+") do
    segments[#segments + 1] = seg
  end
  for i = 1, #segments do
    local cls = classes[cls_name]
    if not cls then
      return false
    end
    local ftype = cls[segments[i]]
    if not ftype then
      return false
    end
    if i < #segments then
      local next_cls = ftype:match("^([%w_%.]+)")
      if not next_cls or not classes[next_cls] then
        return false
      end
      cls_name = next_cls
    end
  end
  return true
end

local function collect_hl_paths_from_source(source)
  local found = {}
  -- Scan both direct hl.* / hl_api.* uses and quoted "hl.*" paths.
  for path in source:gmatch("hl_api%.([%w_%.]+)") do
    found["hl." .. path] = true
  end
  for path in source:gmatch("[^%w_]hl%.([%w_%.]+)") do
    found["hl." .. path] = true
  end
  for path in source:gmatch('"hl%.([%w_%.]+)"') do
    found["hl." .. path] = true
  end
  return found
end

H.test("loader exports api_version, required_api and required_fields", function()
  H.assert_eq(loader.api_version, 1)
  H.assert_true(type(loader.required_api) == "table" and #loader.required_api > 0)
  H.assert_true(type(loader.required_fields) == "table")
  H.assert_true(type(loader.required_fields.window) == "table" and #loader.required_fields.window > 0)
  H.assert_true(type(loader.required_fields.monitor) == "table" and #loader.required_fields.monitor > 0)
  H.assert_true(type(loader.required_fields.workspace) == "table" and #loader.required_fields.workspace > 0)
end)

H.test("all hl.* paths used by the loader and example exist in hl.meta.lua", function()
  local stubs = read_file(STUBS_PATH)
  if not stubs then
    print("contract_test: " .. STUBS_PATH .. " not found, skipped")
    return
  end

  local classes = parse_stub_classes(stubs)
  H.assert_true(classes["HL.API"] ~= nil, "HL.API class must exist in stubs")
  H.assert_false(stub_has_hl_path(classes, "hl.dsp.nonexistent"), "stub checker must reject unknown paths")

  local paths = {}
  for i = 1, #loader.required_api do
    local p = loader.required_api[i]
    if p:sub(1, 3) == "hl." then
      paths[p] = true
    end
  end
  paths["hl.dsp.window.center"] = true

  local loader_src = read_file("hypr/window-rules.lua")
  H.assert_true(type(loader_src) == "string")
  for p in pairs(collect_hl_paths_from_source(loader_src)) do
    paths[p] = true
  end

  local example_src = read_file("examples/hyprland.lua")
  H.assert_true(type(example_src) == "string")
  for p in pairs(collect_hl_paths_from_source(example_src)) do
    paths[p] = true
  end

  local sorted = {}
  for p in pairs(paths) do
    sorted[#sorted + 1] = p
  end
  table.sort(sorted)
  H.assert_true(#sorted >= 10, "expected at least 10 hl.* paths to verify")

  for i = 1, #sorted do
    H.assert_true(
      stub_has_hl_path(classes, sorted[i]),
      "hl.* path not found in " .. STUBS_PATH .. ": " .. sorted[i]
    )
  end
end)

H.test("all HL.Window, HL.Monitor and HL.Workspace fields read by the loader exist in hl.meta.lua", function()
  local stubs = read_file(STUBS_PATH)
  if not stubs then
    print("contract_test: " .. STUBS_PATH .. " not found, skipped")
    return
  end

  local classes = parse_stub_classes(stubs)
  local class_map = {
    window = "HL.Window",
    monitor = "HL.Monitor",
    workspace = "HL.Workspace",
  }

  for key, cls_name in pairs(class_map) do
    local stub_cls = classes[cls_name]
    H.assert_true(stub_cls ~= nil, cls_name .. " class must exist in stubs")
    H.assert_nil(stub_cls["nonexistent_field"], "stub checker must reject unknown field on " .. cls_name)

    local fields = loader.required_fields and loader.required_fields[key]
    H.assert_true(type(fields) == "table" and #fields > 0, "required_fields." .. key .. " must be a non-empty list")
    for i = 1, #fields do
      local field = fields[i]
      H.assert_true(
        stub_cls[field] ~= nil,
        cls_name .. "." .. field .. " not found in " .. STUBS_PATH
      )
    end
  end

  for key in pairs(loader.required_fields) do
    H.assert_true(class_map[key] ~= nil, "unexpected group in required_fields: " .. tostring(key))
  end
end)

local function with_temp_dir(fn)
  local tmp = os.tmpname()
  os.remove(tmp)
  H.assert_true(os.execute("mkdir -p '" .. tmp .. "'"))
  local ok, err = pcall(fn, tmp)
  os.execute("rm -rf '" .. tmp .. "'")
  if not ok then
    error(err, 0)
  end
end

local function install_plugin_copy(config_dir)
  local plugin_dir = config_dir .. "/omarchy/plugins/io.github.ltecosta.window-rules"
  H.assert_true(os.execute("mkdir -p '" .. plugin_dir .. "/hypr'"))
  for _, rel in ipairs({ "manifest.json", "hypr/json.lua", "hypr/schema.lua", "hypr/window-rules.lua" }) do
    local content = read_file(rel)
    H.assert_true(content ~= nil, "failed to read " .. rel)
    write_file(plugin_dir .. "/" .. rel, content)
  end
  return plugin_dir
end

local function setup_stubs(monitors)
  local calls = {
    window_rules = {},
    dispatches = {},
    subscriptions = {},
  }
  local function record_dsp(kind)
    return function(arg)
      return { kind = kind, arg = arg }
    end
  end

  _G.o = {
    window = function(match, effects)
      calls.window_rules[#calls.window_rules + 1] = { match = match, effects = effects }
    end,
    workspaces = {
      slots = 10,
      workspace_id = function(monitor, slot)
        return (monitor.block or 0) * 10 + slot
      end,
      focus = function()
        return function() end
      end,
    },
  }
  _G.hl = {
    on = function(event, cb)
      local sub = { event = event, cb = cb, remove = function() end }
      calls.subscriptions[#calls.subscriptions + 1] = sub
      return sub
    end,
    dispatch = function(action)
      calls.dispatches[#calls.dispatches + 1] = action
    end,
    get_monitors = function()
      return monitors or {}
    end,
    get_monitor = function()
      return nil
    end,
    get_workspace = function()
      return nil
    end,
    get_windows = function()
      return {}
    end,
    get_window = function()
      return nil
    end,
    get_active_window = function()
      return nil
    end,
    get_active_monitor = function()
      return monitors and monitors[1] or nil
    end,
    get_active_workspace = function()
      return nil
    end,
    dsp = {
      focus = record_dsp("focus"),
      workspace = { move = record_dsp("workspace.move") },
      window = { move = record_dsp("window.move"), center = record_dsp("window.center") },
    },
  }
  return calls
end

local function with_env_vars(vars, fn)
  local real_getenv = os.getenv
  os.getenv = function(name)
    if vars[name] ~= nil then
      if vars[name] == false then
        return nil
      end
      return vars[name]
    end
    return real_getenv(name)
  end
  local ok, err = pcall(fn)
  os.getenv = real_getenv
  if not ok then
    error(err, 0)
  end
end

H.test("examples/hyprland.lua loads plugin, registers external-slot and enforces slot bounds", function()
  local chunk, load_err = loadfile("examples/hyprland.lua")
  H.assert_true(type(chunk) == "function", "examples/hyprland.lua must compile: " .. tostring(load_err))

  with_temp_dir(function(tmp)
    local config_dir = tmp .. "/config"
    local state_dir = tmp .. "/state"
    install_plugin_copy(config_dir)

    local rules_dir = state_dir .. "/omarchy/io.github.ltecosta.window-rules"
    H.assert_true(os.execute("mkdir -p '" .. rules_dir .. "'"))
    write_file(rules_dir .. "/rules.json", json.encode({
      version = 1,
      revision = 2,
      rules = setmetatable({
        {
          id = "valid-slot",
          name = "Valid Slot",
          match = { class = "^game$" },
          workspace = { type = "resolver", resolver = "external-slot", arg = 3 },
        },
        {
          id = "out-of-range",
          name = "Out of Range",
          match = { class = "^bad$" },
          workspace = { type = "resolver", resolver = "external-slot", arg = 11 },
        },
      }, json.array_mt),
    }))

    local edp = { name = "eDP-1", block = 0, is_mirror = false }
    local dp = { name = "DP-1", block = 1, is_mirror = false }
    local mirror = { name = "HDMI-1", block = 2, is_mirror = true }
    local calls = setup_stubs({ mirror, edp, dp })
    _G.window_rules = nil

    with_env_vars({ XDG_CONFIG_HOME = config_dir, XDG_STATE_HOME = state_dir, HOME = tmp }, function()
      local ok, run_err = pcall(chunk)
      H.assert_true(ok, "examples/hyprland.lua must not raise: " .. tostring(run_err))
    end)

    H.assert_true(type(_G.window_rules) == "table", "window_rules global must be loaded")
    local desc, dec_err = json.decode(_G.window_rules.describe())
    H.assert_nil(dec_err)
    H.assert_eq(desc.loaded, true)
    H.assert_eq(desc.rules, 2)
    H.assert_eq(desc.dynamic, 2)
    H.assert_eq(#desc.resolvers, 1)
    H.assert_eq(desc.resolvers[1].name, "external-slot")
    H.assert_eq(#desc.errors, 0)

    local cb = calls.subscriptions[1].cb
    -- Valid slot 3 -> non-mirrored external DP-1 (block 1 -> ws 13).
    cb({ address = "0x1", class = "game", pid = 10, workspace = { id = 1 }, tags = { "window-rules:valid-slot*" } })
    local last = calls.dispatches[#calls.dispatches]
    H.assert_eq(last.kind, "window.move")
    H.assert_eq(last.arg.workspace, "13")

    -- Slot 11 (outside 1..o.workspaces.slots) -> resolver returns nil (declines quietly, no move, no error).
    local before = #calls.dispatches
    cb({ address = "0x2", class = "bad", pid = 11, workspace = { id = 1 }, tags = { "window-rules:out-of-range*" } })
    H.assert_eq(#calls.dispatches, before)
    desc = json.decode(_G.window_rules.describe())
    H.assert_eq(#desc.errors, 0)
  end)
end)

H.test("examples/hyprland.lua does nothing when plugin is missing or broken", function()
  local chunk, load_err = loadfile("examples/hyprland.lua")
  H.assert_true(type(chunk) == "function", "examples/hyprland.lua must compile: " .. tostring(load_err))

  with_temp_dir(function(tmp)
    setup_stubs({})
    _G.window_rules = nil

    -- Missing plugin file.
    with_env_vars({ XDG_CONFIG_HOME = tmp .. "/missing", HOME = tmp }, function()
      local ok, run_err = pcall(chunk)
      H.assert_true(ok, "missing plugin must not raise: " .. tostring(run_err))
    end)
    H.assert_nil(_G.window_rules)

    -- Relative XDG_CONFIG_HOME and absent HOME.
    with_env_vars({ XDG_CONFIG_HOME = "relative/config", HOME = false }, function()
      local ok, run_err = pcall(chunk)
      H.assert_true(ok, "relative XDG_CONFIG_HOME and missing HOME must not raise: " .. tostring(run_err))
    end)
    H.assert_nil(_G.window_rules)

    -- Broken plugin file (e.g. partial install) is caught by pcall(dofile).
    local broken_dir = tmp .. "/broken/omarchy/plugins/io.github.ltecosta.window-rules/hypr"
    H.assert_true(os.execute("mkdir -p '" .. broken_dir .. "'"))
    write_file(broken_dir .. "/window-rules.lua", 'error("partial install")')
    with_env_vars({ XDG_CONFIG_HOME = tmp .. "/broken", HOME = tmp }, function()
      local ok, run_err = pcall(chunk)
      H.assert_true(ok, "broken plugin must not raise: " .. tostring(run_err))
    end)
    H.assert_nil(_G.window_rules)
  end)
end)

H.finish("contract_test")
