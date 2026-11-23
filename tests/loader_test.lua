-- Tests for hypr/window-rules.lua with stubbed hl and o globals.

local H = dofile("tests/lua_helpers.lua")
local json = dofile("hypr/json.lua")

local loader = dofile("hypr/window-rules.lua")

local function write_temp_file(content)
  local path = os.tmpname()
  local f, err = io.open(path, "wb")
  H.assert_true(f ~= nil, "failed to create temp file: " .. tostring(err))
  f:write(content)
  f:close()
  return path
end

local function with_temp_rules(tbl_or_str, fn)
  local content = type(tbl_or_str) == "string" and tbl_or_str or json.encode(tbl_or_str)
  local path = write_temp_file(content)
  local ok, err = pcall(fn, path)
  os.remove(path)
  if not ok then
    error(err, 0)
  end
end

local function make_env(opts)
  opts = opts or {}
  local calls = {
    window_rules = {},
    dispatches = {},
    focus_slots = {},
    subscriptions = {},
  }

  local monitors_by_key = opts.monitors or {}
  local workspaces_by_id = opts.workspaces or {}
  local windows_by_addr = opts.windows_by_addr or {}
  local window_list = opts.windows or {}
  local active_window = opts.active_window
  local active_monitor = opts.active_monitor
  local active_workspace = opts.active_workspace

  local function record_dsp(kind)
    return function(arg)
      return { kind = kind, arg = arg }
    end
  end

  local env = {
    calls = calls,
    set_active_monitor = function(mon)
      active_monitor = mon
    end,
    set_active_window = function(win)
      active_window = win
    end,
    set_active_workspace = function(ws)
      active_workspace = ws
    end,
    set_windows = function(list)
      window_list = list
    end,
  }

  _G.o = {
    window = function(match, effects)
      if opts.on_window then
        opts.on_window(match, effects)
      end
      calls.window_rules[#calls.window_rules + 1] = { match = match, effects = effects }
    end,
    workspaces = {
      slots = 10,
      workspace_id = function(monitor, slot)
        local block = monitor.block or 0
        return block * 10 + slot
      end,
      focus = function(slot, monitor_name)
        return function()
          calls.focus_slots[#calls.focus_slots + 1] = { slot = slot, monitor = monitor_name }
          if opts.on_focus_slot then
            opts.on_focus_slot(slot, monitor_name)
          end
        end
      end,
    },
  }

  _G.hl = {
    on = function(event, cb)
      local sub = { event = event, cb = cb, removed = false }
      function sub:remove()
        self.removed = true
      end
      calls.subscriptions[#calls.subscriptions + 1] = sub
      return sub
    end,
    dispatch = function(action)
      if opts.dispatch_error then
        error(opts.dispatch_error)
      end
      calls.dispatches[#calls.dispatches + 1] = action
      if opts.on_dispatch then
        opts.on_dispatch(action)
      end
    end,
    get_monitor = function(sel)
      return monitors_by_key[sel]
    end,
    get_workspace = function(id)
      return workspaces_by_id[id]
    end,
    get_windows = function()
      return window_list
    end,
    get_window = function(sel)
      local addr = type(sel) == "string" and sel:match("^address:(.+)$") or nil
      return addr and windows_by_addr[addr] or nil
    end,
    get_active_window = function()
      return active_window
    end,
    get_active_monitor = function()
      return active_monitor
    end,
    get_active_workspace = function()
      return active_workspace
    end,
    dsp = {
      focus = record_dsp("focus"),
      workspace = {
        move = record_dsp("workspace.move"),
      },
      window = {
        move = record_dsp("window.move"),
        center = record_dsp("window.center"),
      },
    },
  }

  return env
end

local function decode_describe()
  local raw = loader.describe()
  local obj, err = json.decode(raw)
  H.assert_nil(err, "describe() must return valid JSON")
  return obj
end

H.test("global window_rules is set and matches returned module", function()
  H.assert_eq(_G.window_rules, loader)
end)

H.test("mapping to o.window emits only applicable effects and silent suffix", function()
  local env = make_env()
  local doc = {
    version = 1,
    revision = 5,
    rules = setmetatable({
      {
        id = "chat",
        name = "Chat",
        enabled = true,
        match = { class = "^chat$", title = "" },
        workspace = { type = "id", id = 1 },
        follow = false,
        layout = "default",
        fullscreen = false,
        maximize = false,
        pin = false,
        noInitialFocus = false,
      },
      {
        id = "editor",
        name = "Editor",
        enabled = true,
        match = { class = "^code$", title = "^Notes$" },
        workspace = { type = "special", name = "scratchpad" },
        follow = true,
        layout = "float",
        size = { 1200, 800 },
        position = { type = "at", x = 40, y = 60 },
        monitor = "desc:Vendor Model Serial",
        fullscreen = false,
        maximize = true,
        pin = true,
        opacity = 0.9,
        noInitialFocus = true,
      },
      {
        id = "centered",
        name = "Centered",
        enabled = true,
        match = { class = "^pop$" },
        layout = "tile",
        position = { type = "center" },
        fullscreen = true,
      },
      {
        id = "disabled-one",
        name = "Disabled",
        enabled = false,
        match = { class = "^off$" },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  H.assert_eq(#env.calls.window_rules, 3, "disabled rule should not be registered")
  H.assert_eq(#env.calls.subscriptions, 0, "no dynamic rules means no window.open handler")

  local r1 = env.calls.window_rules[1]
  H.assert_eq(r1.match.class, "^chat$")
  H.assert_nil(r1.match.title, "empty title must not be emitted")
  H.assert_eq(r1.effects.name, "window-rules/chat")
  H.assert_eq(r1.effects.tag, "+window-rules:chat")
  H.assert_eq(r1.effects.workspace, "1 silent")
  H.assert_nil(r1.effects.tile)
  H.assert_nil(r1.effects.float)
  H.assert_nil(r1.effects.fullscreen)
  H.assert_nil(r1.effects.maximize)
  H.assert_nil(r1.effects.pin)
  H.assert_nil(r1.effects.no_initial_focus)
  H.assert_nil(r1.effects.opacity)

  local r2 = env.calls.window_rules[2]
  H.assert_eq(r2.match.title, "^Notes$")
  H.assert_eq(r2.effects.workspace, "special:scratchpad")
  H.assert_eq(r2.effects.float, true)
  H.assert_deep_eq(r2.effects.size, { 1200, 800 })
  H.assert_deep_eq(r2.effects.move, { 40, 60 })
  H.assert_eq(r2.effects.monitor, "desc:Vendor Model Serial")
  H.assert_eq(r2.effects.maximize, true)
  H.assert_eq(r2.effects.pin, true)
  H.assert_eq(r2.effects.opacity, "0.9")
  H.assert_eq(r2.effects.no_initial_focus, true)

  local r3 = env.calls.window_rules[3]
  H.assert_eq(r3.effects.tile, true)
  H.assert_eq(r3.effects.center, true)
  H.assert_eq(r3.effects.fullscreen, true)

  local desc = decode_describe()
  H.assert_eq(desc.loaded, true)
  H.assert_eq(desc.loaderVersion, "1.0.0")
  H.assert_eq(desc.schema, 1)
  H.assert_eq(desc.revision, 5)
  H.assert_eq(desc.rules, 3)
  H.assert_eq(desc.dynamic, 0)
  H.assert_eq(#desc.errors, 0)
end)

H.test("mapping to o.window compiles apps, exact-title and initial match tables", function()
  local env = make_env()
  local doc = {
    version = 1,
    revision = 1,
    rules = setmetatable({
      {
        id = "apps-only",
        name = "Apps Only",
        match = {
          mode = "apps",
          classes = setmetatable({ "com.microsoft.VSCode", "teams-for-linux" }, json.array_mt),
        },
        workspace = { type = "special", name = "scratchpad" },
      },
      {
        id = "exact-title",
        name = "Exact Title",
        match = {
          mode = "apps",
          classes = setmetatable({ "steam" }, json.array_mt),
          title = "Steam - News",
          titleMode = "exact",
        },
        layout = "float",
      },
      {
        id = "initial-exact",
        name = "Initial Exact",
        match = {
          mode = "apps",
          classes = setmetatable({ "a.b" }, json.array_mt),
          title = "Pop (1)",
          titleMode = "exact",
          initial = true,
        },
        pin = true,
      },
      {
        id = "initial-regex-no-title",
        name = "Initial Regex No Title",
        match = {
          mode = "regex",
          class = "^foo$",
          title = "",
          initial = true,
        },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  H.assert_eq(#env.calls.window_rules, 4)

  H.assert_deep_eq(env.calls.window_rules[1].match, {
    class = "^(com\\.microsoft\\.VSCode|teams\\-for\\-linux)$",
  })

  H.assert_deep_eq(env.calls.window_rules[2].match, {
    class = "^(steam)$",
    title = "^Steam\\ \\-\\ News$",
  })

  H.assert_deep_eq(env.calls.window_rules[3].match, {
    initial_class = "^(a\\.b)$",
    initial_title = "^Pop\\ \\(1\\)$",
  })

  H.assert_deep_eq(env.calls.window_rules[4].match, {
    initial_class = "^foo$",
  })
end)

H.test("missing file, invalid JSON, unsupported version and oversized file", function()
  make_env()
  local missing_path = os.tmpname()
  os.remove(missing_path)
  H.assert_true(loader.load(missing_path))
  local desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(#desc.errors, 0)

  with_temp_rules("{not json", function(path)
    H.assert_false(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].code, "invalid-json")
  H.assert_eq(desc.errors[1].id, json.null)

  with_temp_rules({ version = 2, rules = setmetatable({}, json.array_mt) }, function(path)
    H.assert_false(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(desc.errors[1].code, "unsupported-version")

  local huge = string.rep(" ", 1048577)
  with_temp_rules(huge, function(path)
    H.assert_false(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(desc.errors[1].code, "file-too-large")
end)

H.test("invalid rule skipped with code while valid rules register", function()
  local env = make_env()
  local doc = {
    version = 1,
    revision = 2,
    rules = setmetatable({
      { id = "good-1", name = "Good 1", match = { class = "^a$" } },
      { id = "bad-1", name = "Bad 1", match = { class = "^b$" }, opacity = 5 },
      { id = "good-2", name = "Good 2", match = { class = "^c$" } },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  H.assert_eq(#env.calls.window_rules, 2)
  local desc = decode_describe()
  H.assert_eq(desc.rules, 2)
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].id, "bad-1")
  H.assert_eq(desc.errors[1].code, "invalid-opacity")
end)

H.test("precedence: earlier dynamic + later static = no move; earlier static + later dynamic = move", function()
  local mon = { name = "DP-1", block = 1, x = 1920, y = 0 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [13] = { id = 13, monitor = mon } },
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "dyn-early",
        name = "Dyn Early",
        match = { class = "^app$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 3 },
      },
      {
        id = "static-mid",
        name = "Static Mid",
        match = { class = "^app$" },
        workspace = { type = "id", id = 1 },
      },
      {
        id = "dyn-late",
        name = "Dyn Late",
        match = { class = "^app$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 4 },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb

  -- Earlier dynamic + later static -> static wins -> no move.
  cb({
    address = "0x1",
    class = "app",
    pid = 100,
    workspace = { id = 1 },
    tags = { "window-rules:dyn-early*", "window-rules:static-mid*" },
  })
  H.assert_eq(#env.calls.dispatches, 0)

  -- Earlier static + later dynamic -> dynamic wins -> moves to slot 4 (ws 14).
  cb({
    address = "0x2",
    class = "app",
    pid = 101,
    workspace = { id = 1 },
    tags = { "window-rules:static-mid*", "window-rules:dyn-late*" },
  })
  H.assert_eq(#env.calls.focus_slots, 1)
  H.assert_eq(env.calls.focus_slots[1].slot, 4)
  H.assert_eq(env.calls.focus_slots[1].monitor, "DP-1")
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "14")
  H.assert_eq(env.calls.dispatches[1].arg.follow, true)
  H.assert_eq(env.calls.dispatches[1].arg.window, "address:0x2")
end)

H.test("already on target, first window by (pid, class), second window silent", function()
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local prev_win = {
    address = "0x99",
    workspace = { id = 1, visible = true, special = false },
    monitor = { name = "eDP-1" },
  }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [13] = { id = 13, monitor = mon } },
    active_window = prev_win,
    active_monitor = { name = "DP-1" },
    windows_by_addr = { ["0x99"] = prev_win },
  })

  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "steam",
        name = "Steam",
        match = { class = "^steam$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 3 },
        follow = true,
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb

  -- Already on workspace 13 -> no move.
  cb({
    address = "0x10",
    class = "steam",
    pid = 500,
    workspace = { id = 13 },
    tags = { "window-rules:steam*" },
  })
  H.assert_eq(#env.calls.dispatches, 0)

  -- First window of (pid=500, class="steam") -> follow = true even if another class shares pid 500.
  env.set_windows({
    { address = "0x01", pid = 500, class = "other-webapp" },
    { address = "0x11", pid = 500, class = "steam" },
  })
  cb({
    address = "0x11",
    class = "steam",
    pid = 500,
    workspace = { id = 1 },
    tags = { "window-rules:steam*" },
  })
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].arg.follow, true)

  -- Second window of same (pid=500, class="steam") while sibling is on target (ws 13) -> follow = false (silent).
  env.set_windows({
    { address = "0x11", pid = 500, class = "steam", workspace = { id = 13 } },
    { address = "0x12", pid = 500, class = "steam", workspace = { id = 1 } },
  })
  cb({
    address = "0x12",
    class = "steam",
    pid = 500,
    workspace = { id = 1 },
    tags = { "window-rules:steam*" },
  })
  H.assert_eq(#env.calls.dispatches, 2)
  H.assert_eq(env.calls.dispatches[2].arg.follow, false)
  H.assert_eq(env.calls.dispatches[2].arg.window, "address:0x12")

  -- Second window of same (pid=500, class="steam") after user moved sibling off target (ws 2) -> do not move.
  env.set_windows({
    { address = "0x11", pid = 500, class = "steam", workspace = { id = 2 } },
    { address = "0x13", pid = 500, class = "steam", workspace = { id = 2 } },
  })
  cb({
    address = "0x13",
    class = "steam",
    pid = 500,
    workspace = { id = 2 },
    tags = { "window-rules:steam*" },
  })
  H.assert_eq(#env.calls.dispatches, 2, "sibling moved off target must prevent dragging later windows back")
end)

H.test("silent move restores previous focus for visible workspaces, special ones included", function()
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local prev_regular = {
    address = "0xaa",
    workspace = { id = 1, visible = true, special = false },
    monitor = { name = "eDP-1" },
  }
  local prev_special = {
    address = "0xbb",
    workspace = { id = -99, visible = true, special = true },
    monitor = { name = "eDP-1" },
  }

  -- Case 1: previous window is on visible, non-special workspace -> restored after creating missing workspace.
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = {},
    active_window = prev_regular,
    active_monitor = { name = "DP-1" },
    windows_by_addr = { ["0xaa"] = prev_regular, ["0xbb"] = prev_special },
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "bg",
        name = "BG",
        match = { class = "^bg$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
        follow = false,
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb
  cb({
    address = "0x20",
    class = "bg",
    pid = 700,
    workspace = { id = 1 },
    tags = { "window-rules:bg*" },
  })
  H.assert_eq(#env.calls.focus_slots, 1)
  H.assert_eq(#env.calls.dispatches, 3)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.follow, false)
  H.assert_eq(env.calls.dispatches[2].kind, "focus")
  H.assert_eq(env.calls.dispatches[2].arg.monitor, "eDP-1")
  H.assert_eq(env.calls.dispatches[3].kind, "focus")
  H.assert_eq(env.calls.dispatches[3].arg.window, "address:0xaa")

  -- Case 2: previous window is on an open (visible) special workspace, such as a
  -- drop-down console -> focus goes back to it, its monitor first.
  env.set_active_window(prev_special)
  local before = #env.calls.dispatches
  cb({
    address = "0x21",
    class = "bg",
    pid = 701,
    workspace = { id = 1 },
    tags = { "window-rules:bg*" },
  })
  H.assert_eq(#env.calls.dispatches - before, 3)
  H.assert_eq(env.calls.dispatches[before + 1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[before + 2].arg.monitor, "eDP-1")
  H.assert_eq(env.calls.dispatches[before + 3].arg.window, "address:0xbb")

  -- Case 3: previous window is on a hidden special workspace -> its window is not
  -- focused (that would open the workspace); only the previous monitor is.
  local prev_hidden = {
    address = "0xcc",
    workspace = { id = -98, visible = false, special = true },
    monitor = { name = "eDP-1" },
  }
  env.set_active_window(prev_hidden)
  before = #env.calls.dispatches
  cb({
    address = "0x22",
    class = "bg",
    pid = 702,
    workspace = { id = 1 },
    tags = { "window-rules:bg*" },
  })
  H.assert_eq(#env.calls.dispatches - before, 2)
  H.assert_eq(env.calls.dispatches[before + 1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[before + 2].kind, "focus")
  H.assert_eq(env.calls.dispatches[before + 2].arg.monitor, "DP-1")

  -- Case 4: Hyprland already focused the new window when window.open runs ->
  -- the previous window comes from the focus history.
  local new_window = {
    address = "0x23",
    class = "bg",
    pid = 703,
    workspace = { id = 1, visible = true, special = false },
    focus_history_id = 0,
    tags = { "window-rules:bg*" },
  }
  prev_special.focus_history_id = 1
  prev_regular.focus_history_id = 2
  env.set_windows({ new_window, prev_special, prev_regular })
  env.set_active_window(new_window)
  before = #env.calls.dispatches
  cb(new_window)
  H.assert_eq(#env.calls.dispatches - before, 3)
  H.assert_eq(env.calls.dispatches[before + 3].arg.window, "address:0xbb")

  -- Case 5: no window had focus (an empty workspace) -> the previous monitor and
  -- regular workspace are shown again, since creating the target focused it.
  env.set_windows({})
  env.set_active_window(nil)
  env.set_active_workspace({ id = 4, special = false })
  before = #env.calls.dispatches
  cb({ address = "0x24", class = "bg", pid = 704, workspace = { id = 1 }, tags = { "window-rules:bg*" } })
  H.assert_eq(#env.calls.dispatches - before, 3)
  H.assert_eq(env.calls.dispatches[before + 2].arg.monitor, "DP-1")
  H.assert_eq(env.calls.dispatches[before + 3].arg.workspace, "4")
end)

H.test("resolver target creation, wrong monitor move, raising/garbage resolver, missing resolver", function()
  local dp1 = { name = "DP-1", x = 1920, y = 0 }
  local edp1 = { name = "eDP-1", x = 0, y = 0 }
  local env = make_env({
    monitors = { ["DP-1"] = dp1, ["eDP-1"] = edp1 },
    workspaces = {
      [12] = { id = 12, monitor = edp1 }, -- sits on wrong monitor
    },
  })

  H.assert_true(loader.register_resolver("ext-slot", {
    label = "External display slot",
    arg_label = "Slot",
    resolve = function(arg)
      if arg == 2 then
        return { workspace = 12, monitor = "DP-1" }
      elseif arg == 3 then
        return { workspace = 13, monitor = "DP-1" }
      elseif arg == 4 then
        error("boom")
      else
        return "garbage"
      end
    end,
  }))

  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "vm",
        name = "VM",
        match = { class = "^vm$" },
        workspace = { type = "resolver", resolver = "ext-slot", arg = 2 },
      },
      {
        id = "game",
        name = "Game",
        match = { class = "^game$" },
        workspace = { type = "resolver", resolver = "ext-slot", arg = 3 },
      },
      {
        id = "crash",
        name = "Crash",
        match = { class = "^crash$" },
        workspace = { type = "resolver", resolver = "ext-slot", arg = 4 },
      },
      {
        id = "badret",
        name = "BadRet",
        match = { class = "^badret$" },
        workspace = { type = "resolver", resolver = "ext-slot", arg = 5 },
      },
      {
        id = "nores",
        name = "NoRes",
        match = { class = "^nores$" },
        workspace = { type = "resolver", resolver = "missing-res", arg = 1 },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local desc = decode_describe()
  H.assert_eq(desc.dynamic, 5)
  H.assert_eq(#desc.resolvers, 1)
  H.assert_eq(desc.resolvers[1].name, "ext-slot")
  H.assert_eq(desc.resolvers[1].label, "External display slot")
  H.assert_eq(desc.resolvers[1].argLabel, "Slot")
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].id, "nores")
  H.assert_eq(desc.errors[1].code, "resolver-missing")

  local cb = env.calls.subscriptions[1].cb

  -- Workspace 12 exists on wrong monitor (eDP-1) -> workspace.move then window.move.
  cb({ address = "0x30", class = "vm", pid = 1, workspace = { id = 1 }, tags = { "window-rules:vm*" } })
  H.assert_eq(env.calls.dispatches[1].kind, "workspace.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "12")
  H.assert_eq(env.calls.dispatches[1].arg.monitor, "DP-1")
  H.assert_eq(env.calls.dispatches[2].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].arg.workspace, "12")

  -- Workspace 13 missing -> focus monitor, focus workspace, then window.move.
  local off = #env.calls.dispatches
  cb({ address = "0x31", class = "game", pid = 2, workspace = { id = 1 }, tags = { "window-rules:game*" } })
  H.assert_eq(env.calls.dispatches[off + 1].kind, "focus")
  H.assert_eq(env.calls.dispatches[off + 1].arg.monitor, "DP-1")
  H.assert_eq(env.calls.dispatches[off + 2].kind, "focus")
  H.assert_eq(env.calls.dispatches[off + 2].arg.workspace, "13")
  H.assert_eq(env.calls.dispatches[off + 3].kind, "window.move")
  H.assert_eq(env.calls.dispatches[off + 3].arg.workspace, "13")

  -- Raising and garbage resolvers -> resolver-failed recorded, no crash, no dispatch.
  off = #env.calls.dispatches
  cb({ address = "0x32", class = "crash", pid = 3, workspace = { id = 1 }, tags = { "window-rules:crash*" } })
  cb({ address = "0x33", class = "badret", pid = 4, workspace = { id = 1 }, tags = { "window-rules:badret*" } })
  H.assert_eq(#env.calls.dispatches, off)

  desc = decode_describe()
  H.assert_eq(#desc.errors, 3)
  H.assert_eq(desc.errors[2].id, "crash")
  H.assert_eq(desc.errors[2].code, "resolver-failed")
  H.assert_eq(desc.errors[3].id, "badret")
  H.assert_eq(desc.errors[3].code, "resolver-failed")

  -- A resolver that keeps failing reports once per rule, not once per window.
  cb({ address = "0x34", class = "crash", pid = 5, workspace = { id = 1 }, tags = { "window-rules:crash*" } })
  cb({ address = "0x35", class = "crash", pid = 6, workspace = { id = 1 }, tags = { "window-rules:crash*" } })
  desc = decode_describe()
  H.assert_eq(#desc.errors, 3)
end)

H.test("handler accepts the userdata window objects Hyprland passes", function()
  local env = make_env({ monitors = {}, workspaces = {} })
  H.assert_true(loader.register_resolver("ud", {
    label = "Userdata",
    resolve = function() return { workspace = 7 } end,
  }))
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "ud", name = "UD", match = { class = "^ud$" }, workspace = { type = "resolver", resolver = "ud", arg = 1 } },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  -- A full userdata (a temporary file handle) with its own metatable stands in
  -- for HL.Window: field reads work, but type() is "userdata", not "table".
  local window = io.tmpfile()
  window:close()
  debug.setmetatable(window, {
    __index = { address = "0x40", class = "ud", pid = 9, workspace = { id = 1 }, tags = { "window-rules:ud*" } },
  })
  H.assert_eq(type(window), "userdata")

  env.calls.subscriptions[1].cb(window)
  local last = env.calls.dispatches[#env.calls.dispatches]
  H.assert_eq(last.kind, "window.move")
  H.assert_eq(last.arg.workspace, "7")
  H.assert_eq(last.arg.window, "address:0x40")
end)

H.test("a resolver returning nil declines quietly", function()
  local env = make_env({ monitors = {}, workspaces = {} })
  H.assert_true(loader.register_resolver("nothing-now", {
    label = "Declines",
    resolve = function() return nil end,
  }))
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "quiet", name = "Quiet", match = { class = "^quiet$" }, workspace = { type = "resolver", resolver = "nothing-now", arg = 1 } },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)
  env.calls.subscriptions[1].cb({ address = "0x50", class = "quiet", pid = 1, workspace = { id = 1 }, tags = { "window-rules:quiet*" } })
  H.assert_eq(#env.calls.dispatches, 0)
  H.assert_eq(#decode_describe().errors, 0)
end)

H.test("a relative XDG_STATE_HOME is ignored for the default rules path", function()
  local env = make_env({})
  local home = os.tmpname()
  os.remove(home)
  local dir = home .. "/.local/state/omarchy/io.github.ltecosta.window-rules"
  H.assert_true(os.execute("mkdir -p '" .. dir .. "'"))
  local file = assert(io.open(dir .. "/rules.json", "w"))
  file:write('{"version":1,"revision":5,"rules":[{"id":"x","name":"X","match":{"class":"^x$"}}]}')
  file:close()

  local getenv = os.getenv
  os.getenv = function(name)
    if name == "XDG_STATE_HOME" then return "relative/state" end
    if name == "HOME" then return home end
    return getenv(name)
  end
  local ok, err = pcall(loader.load)
  os.getenv = getenv
  os.execute("rm -r '" .. home .. "'")
  H.assert_true(ok, err)

  local desc = decode_describe()
  H.assert_eq(desc.revision, 5)
  H.assert_eq(desc.rules, 1)
  H.assert_eq(#env.calls.window_rules, 1)
end)

H.test("a declining dynamic rule falls back to an earlier static target it unset", function()
  local env = make_env({ monitors = {}, workspaces = {} })
  H.assert_true(loader.register_resolver("away", { label = "Away", resolve = function() return nil end }))
  with_temp_rules({
    version = 1,
    rules = setmetatable({
      { id = "home", name = "Home", match = { class = "^fb$" }, workspace = { type = "id", id = 5 } },
      { id = "pad", name = "Pad", match = { class = "^fbs$" }, workspace = { type = "special", name = "scratchpad" }, follow = false },
      { id = "ext", name = "Ext", match = { class = "^fbs?$" }, workspace = { type = "resolver", resolver = "away", arg = 1 } },
    }, json.array_mt),
  }, function(path)
    loader.load(path)
  end)
  local cb = env.calls.subscriptions[1].cb

  cb({ address = "0x60", class = "fb", pid = 20, workspace = { id = 1, name = "1" }, tags = { "window-rules:home*", "window-rules:ext*" } })
  local move = env.calls.dispatches[#env.calls.dispatches]
  H.assert_eq(move.kind, "window.move")
  H.assert_eq(move.arg.workspace, "5")

  cb({ address = "0x61", class = "fbs", pid = 21, workspace = { id = 1, name = "1" }, tags = { "window-rules:pad*", "window-rules:ext*" } })
  move = env.calls.dispatches[#env.calls.dispatches]
  H.assert_eq(move.kind, "window.move")
  H.assert_eq(move.arg.workspace, "special:scratchpad")
  H.assert_eq(move.arg.follow, false)

  -- Without a dynamic rule above it, a static target is left to Hyprland.
  local before = #env.calls.dispatches
  cb({ address = "0x62", class = "fb", pid = 22, workspace = { id = 1, name = "1" }, tags = { "window-rules:home*" } })
  H.assert_eq(#env.calls.dispatches, before)
end)

H.test("absent monitor does nothing and records no error", function()
  local env = make_env({ monitors = {} })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "ext",
        name = "Ext",
        match = { class = "^ext$" },
        workspace = { type = "monitor-slot", monitor = "desc:Absent", slot = 2 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  env.calls.subscriptions[1].cb({
    address = "0x40",
    class = "ext",
    pid = 10,
    workspace = { id = 1 },
    tags = { "window-rules:ext*" },
  })
  H.assert_eq(#env.calls.dispatches, 0)
  H.assert_eq(#decode_describe().errors, 0)
end)

H.test("missing capability keeps static rules and disables dynamic with capability-missing", function()
  local env = make_env()
  _G.o.workspaces.focus = nil
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "st", name = "Static", match = { class = "^st$" }, workspace = { type = "id", id = 1 } },
      {
        id = "dy",
        name = "Dynamic",
        match = { class = "^dy$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  H.assert_eq(#env.calls.window_rules, 2)
  H.assert_eq(#env.calls.subscriptions, 0)
  local desc = decode_describe()
  H.assert_eq(desc.dynamic, 0)
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].code, "capability-missing")
end)

H.test("load() twice removes previous window.open subscription", function()
  local env = make_env()
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "dy",
        name = "Dyn",
        match = { class = "^dy$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
    H.assert_eq(#env.calls.subscriptions, 1)
    H.assert_false(env.calls.subscriptions[1].removed)

    loader.load(path)
    H.assert_eq(#env.calls.subscriptions, 2)
    H.assert_true(env.calls.subscriptions[1].removed)
    H.assert_false(env.calls.subscriptions[2].removed)
  end)
end)

H.test("position center and at are reapplied on destination monitor after dynamic move", function()
  local mon = { name = "DP-1", block = 1, x = 1920, y = 100 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [12] = { id = 12, monitor = mon }, [13] = { id = 13, monitor = mon } },
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "centered-dyn",
        name = "Centered Dyn",
        match = { class = "^c$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
        layout = "float",
        position = { type = "center" },
      },
      {
        id = "placed-dyn",
        name = "Placed Dyn",
        match = { class = "^p$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 3 },
        layout = "float",
        position = { type = "at", x = 40, y = 60 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb

  cb({ address = "0x50", class = "c", pid = 1, floating = true, workspace = { id = 1 }, tags = { "window-rules:centered-dyn*" } })
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].kind, "window.center")
  H.assert_eq(env.calls.dispatches[2].arg.window, "address:0x50")

  cb({ address = "0x51", class = "p", pid = 2, floating = true, workspace = { id = 1 }, tags = { "window-rules:placed-dyn*" } })
  H.assert_eq(env.calls.dispatches[3].kind, "window.move")
  H.assert_eq(env.calls.dispatches[4].kind, "window.move")
  H.assert_eq(env.calls.dispatches[4].arg.x, 1960)
  H.assert_eq(env.calls.dispatches[4].arg.y, 160)
  H.assert_eq(env.calls.dispatches[4].arg.relative, false)
  H.assert_eq(env.calls.dispatches[4].arg.window, "address:0x51")

  -- Non-floating window: workspace move runs, position reapply is skipped.
  cb({ address = "0x52", class = "p", pid = 3, floating = false, workspace = { id = 1 }, tags = { "window-rules:placed-dyn*" } })
  H.assert_eq(#env.calls.dispatches, 5)
  H.assert_eq(env.calls.dispatches[5].kind, "window.move")
  H.assert_eq(env.calls.dispatches[5].arg.workspace, "13")
end)

H.test("move_window API and handler-failed recovery", function()
  local mon = { name = "DP-1", x = 0, y = 0 }
  local env = make_env({
    monitors = { ["DP-1"] = mon },
    workspaces = { [15] = { id = 15, monitor = mon } },
  })

  H.assert_true(loader.move_window("0x60", { workspace = 15, monitor = "DP-1" }, true))
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "15")
  H.assert_false(loader.move_window("", { workspace = 15 }, true))
  H.assert_false(loader.move_window("0x60", { workspace = 0 }, true))

  local err_env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = { name = "DP-1", block = 1, x = 0, y = 0 } },
    workspaces = { [12] = { id = 12, monitor = { name = "DP-1" } } },
    dispatch_error = "hyprland dispatch failed",
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "err-case",
        name = "Err",
        match = { class = "^e$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  -- Must not raise out of handler.
  err_env.calls.subscriptions[1].cb({
    address = "0x70",
    class = "e",
    pid = 1,
    workspace = { id = 1 },
    tags = { "window-rules:err-case*" },
  })
  local desc = decode_describe()
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].code, "handler-failed")
end)

-- Simulates Hyprland evaluating registered o.window rules top-to-bottom on a
-- window (applying static workspace, float/tile, and +tag effects) before
-- firing window.open.
local function apply_registered_rules(window_rules, window)
  local tags = {}
  local static_ws = nil
  for i = 1, #window_rules do
    local reg = window_rules[i]
    local class_ok = window.class ~= nil and window.class:match(reg.match.class) ~= nil
    local title_ok = true
    if reg.match.title ~= nil then
      title_ok = window.title ~= nil and window.title:match(reg.match.title) ~= nil
    end
    if class_ok and title_ok then
      if type(reg.effects.tag) == "string" and reg.effects.tag:sub(1, 1) == "+" then
        tags[#tags + 1] = reg.effects.tag:sub(2) .. "*"
      end
      if reg.effects.float == true then
        window.floating = true
      elseif reg.effects.tile == true then
        window.floating = false
      end
      if reg.effects.workspace == "unset" then
        static_ws = nil
      elseif type(reg.effects.workspace) == "string" then
        static_ws = reg.effects.workspace
      end
    end
  end
  window.tags = tags
  return static_ws
end

H.test("R14: previous_window ignores hidden scratchpad with lower focus_history_id", function()
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local new_win = {
    address = "0x100",
    class = "bg",
    pid = 1,
    workspace = { id = 2, visible = true, special = false },
    focus_history_id = 0,
    tags = { "window-rules:bg*" },
  }
  local hidden_1 = {
    address = "0x101",
    workspace = { id = -99, visible = false, special = true },
    monitor = { name = "eDP-1" },
    focus_history_id = 1,
  }
  local hidden_2 = {
    address = "0x102",
    workspace = { id = -99, visible = false, special = true },
    monitor = { name = "eDP-1" },
    focus_history_id = 2,
  }
  local visible_browser = {
    address = "0x103",
    workspace = { id = 2, visible = true, special = false },
    monitor = { name = "eDP-1" },
    focus_history_id = 3,
  }

  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = {},
    windows = { new_win, hidden_1, hidden_2, visible_browser },
    active_window = new_win,
    active_monitor = { name = "DP-1" },
    windows_by_addr = { ["0x101"] = hidden_1, ["0x102"] = hidden_2, ["0x103"] = visible_browser },
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "bg",
        name = "BG",
        match = { class = "^bg$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
        follow = false,
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb
  cb(new_win)

  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].kind, "focus")
  H.assert_eq(env.calls.dispatches[2].arg.monitor, "eDP-1")
  H.assert_eq(env.calls.dispatches[3].kind, "focus")
  H.assert_eq(env.calls.dispatches[3].arg.window, "address:0x103")

  -- Also when active_window itself is on a hidden special workspace, pick the visible one from history.
  env.set_windows({ hidden_1, hidden_2, visible_browser })
  env.set_active_window(hidden_1)
  local before = #env.calls.dispatches
  cb({
    address = "0x104",
    class = "bg",
    pid = 2,
    workspace = { id = 2, visible = true, special = false },
    tags = { "window-rules:bg*" },
  })
  H.assert_eq(env.calls.dispatches[before + 3].arg.window, "address:0x103")
end)

H.test("R15.1: silent move creating workspace on another monitor restores that monitor's workspace", function()
  local dp1 = {
    name = "DP-1",
    block = 1,
    x = 1920,
    y = 0,
    active_workspace = { id = 11, name = "11", special = false, visible = true },
  }
  local edp1 = {
    name = "eDP-1",
    block = 0,
    x = 0,
    y = 0,
    active_workspace = { id = 1, name = "1", special = false, visible = true },
  }
  local prev_win = {
    address = "0x201",
    workspace = { id = 1, visible = true, special = false },
    monitor = edp1,
  }

  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = dp1, ["DP-1"] = dp1, ["eDP-1"] = edp1 },
    workspaces = {},
    active_window = prev_win,
    active_monitor = edp1,
    active_workspace = edp1.active_workspace,
    windows_by_addr = { ["0x201"] = prev_win },
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "bg-ext",
        name = "BG Ext",
        match = { class = "^bg$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
        follow = false,
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb
  cb({ address = "0x202", class = "bg", pid = 10, workspace = { id = 1 }, tags = { "window-rules:bg-ext*" } })

  -- 1: window.move to ws 12 silent; 2-3: restore DP-1 to ws 11; 4-5: restore focus to eDP-1 and 0x201.
  H.assert_eq(#env.calls.focus_slots, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "12")
  H.assert_eq(env.calls.dispatches[1].arg.follow, false)
  H.assert_eq(env.calls.dispatches[2].kind, "focus")
  H.assert_eq(env.calls.dispatches[2].arg.monitor, "DP-1")
  H.assert_eq(env.calls.dispatches[3].kind, "focus")
  H.assert_eq(env.calls.dispatches[3].arg.workspace, "11")
  H.assert_eq(env.calls.dispatches[4].kind, "focus")
  H.assert_eq(env.calls.dispatches[4].arg.monitor, "eDP-1")
  H.assert_eq(env.calls.dispatches[5].kind, "focus")
  H.assert_eq(env.calls.dispatches[5].arg.window, "address:0x201")

  -- Same scenario when user's monitor shows an empty workspace (no focused window).
  env.set_active_window(nil)
  env.set_windows({})
  local before = #env.calls.dispatches
  cb({ address = "0x203", class = "bg", pid = 11, workspace = { id = 1 }, tags = { "window-rules:bg-ext*" } })
  H.assert_eq(env.calls.dispatches[before + 1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[before + 2].arg.monitor, "DP-1")
  H.assert_eq(env.calls.dispatches[before + 3].arg.workspace, "11")
  H.assert_eq(env.calls.dispatches[before + 4].arg.monitor, "eDP-1")
  H.assert_eq(env.calls.dispatches[before + 5].arg.workspace, "1")

  -- Same monitor, with a drop-down console (visible special workspace) over
  -- regular workspace 2: creating workspace 6 there must leave 2 underneath and
  -- give focus back to the console window.
  local panel = {
    name = "eDP-1",
    block = 0,
    x = 0,
    y = 0,
    active_workspace = { id = 2, name = "2", special = false, visible = true },
  }
  local console = {
    address = "0x210",
    workspace = { id = -98, name = "special:console", visible = true, special = true },
    monitor = panel,
  }
  local env2 = make_env({
    monitors = { ["desc:Vendor Panel Serial"] = panel, ["eDP-1"] = panel },
    workspaces = {},
    active_window = console,
    active_monitor = panel,
    active_workspace = console.workspace,
    windows_by_addr = { ["0x210"] = console },
  })
  with_temp_rules({
    version = 1,
    rules = setmetatable({
      { id = "slot6", name = "Slot 6", match = { class = "^s6$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Panel Serial", slot = 6 }, follow = false },
    }, json.array_mt),
  }, function(path)
    loader.load(path)
  end)
  env2.calls.subscriptions[1].cb({ address = "0x211", class = "s6", pid = 12, workspace = { id = 2 }, tags = { "window-rules:slot6*" } })
  H.assert_eq(env2.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env2.calls.dispatches[1].arg.workspace, "6")
  H.assert_eq(env2.calls.dispatches[2].kind, "focus")
  H.assert_eq(env2.calls.dispatches[2].arg.workspace, "2")
  H.assert_eq(env2.calls.dispatches[#env2.calls.dispatches].arg.window, "address:0x210")
end)

H.test("R15.2 & R16 & R21: dynamic emits workspace=unset and later position-only rule wins from rule matching", function()
  local mon = { name = "DP-1", block = 1, x = 100, y = 20 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [13] = { id = 13, monitor = mon } },
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "static-base",
        name = "Static Base",
        match = { class = "^tool$" },
        workspace = { type = "id", id = 9 },
        follow = false,
      },
      {
        id = "dyn-place",
        name = "Dyn Place",
        match = { class = "^tool$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 3 },
        layout = "float",
        position = { type = "at", x = 10, y = 10 },
      },
      {
        id = "pos-override",
        name = "Pos Override",
        match = { class = "^tool$", title = "^Dialog$" },
        position = { type = "at", x = 40, y = 50 },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  -- Dynamic rule emits static workspace = "unset" so earlier static rule does not apply first.
  H.assert_eq(env.calls.window_rules[1].effects.workspace, "9 silent")
  H.assert_eq(env.calls.window_rules[2].effects.workspace, "unset")
  H.assert_nil(env.calls.window_rules[3].effects.workspace)

  -- Start from rule-to-window matching (no hand-built tags).
  local win = { address = "0x301", class = "tool", title = "Dialog", pid = 1, workspace = { id = 1 } }
  local static_ws = apply_registered_rules(env.calls.window_rules, win)
  H.assert_nil(static_ws, "workspace=unset must cancel earlier static workspace")
  H.assert_eq(win.floating, true)

  env.calls.subscriptions[1].cb(win)
  H.assert_eq(#env.calls.dispatches, 2)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "13")
  H.assert_eq(env.calls.dispatches[2].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].arg.x, 140)
  H.assert_eq(env.calls.dispatches[2].arg.y, 70)
  H.assert_eq(env.calls.dispatches[2].arg.relative, false)
end)

H.test("R17: dynamic fallback tries earlier dynamic candidates when winner declines, stops at static", function()
  local home_mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local env = make_env({
    monitors = { ["desc:Home Dock"] = home_mon, ["DP-1"] = home_mon },
    workspaces = { [12] = { id = 12, monitor = home_mon }, [14] = { id = 14, monitor = home_mon } },
  })
  H.assert_true(loader.register_resolver("decliner", {
    label = "Decliner",
    resolve = function()
      return nil
    end,
  }))

  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "dyn-home",
        name = "Home",
        match = { class = "^app$" },
        workspace = { type = "monitor-slot", monitor = "desc:Home Dock", slot = 2 },
      },
      {
        id = "dyn-office",
        name = "Office",
        match = { class = "^app$" },
        workspace = { type = "monitor-slot", monitor = "desc:Office Dock", slot = 4 },
      },
      {
        id = "dyn-res-nil",
        name = "Res Nil",
        match = { class = "^app$" },
        workspace = { type = "resolver", resolver = "decliner", arg = 1 },
      },
      {
        id = "static-barrier",
        name = "Static Barrier",
        match = { class = "^blocked$" },
        workspace = { type = "id", id = 5 },
      },
      {
        id = "dyn-absent-after-static",
        name = "Absent After Static",
        match = { class = "^blocked$" },
        workspace = { type = "monitor-slot", monitor = "desc:Office Dock", slot = 6 },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    loader.load(path)
  end)

  local cb = env.calls.subscriptions[1].cb

  -- Resolver returns nil, office monitor absent -> falls back to dyn-home (ws 12).
  cb({
    address = "0x401",
    class = "app",
    pid = 1,
    workspace = { id = 1 },
    tags = { "window-rules:dyn-home*", "window-rules:dyn-office*", "window-rules:dyn-res-nil*" },
  })
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "12")
  H.assert_eq(#decode_describe().errors, 0)

  -- Absent dynamic rule followed by earlier static barrier -> stops at static, does not fall back to dyn-home.
  cb({
    address = "0x402",
    class = "blocked",
    pid = 2,
    workspace = { id = 5 },
    tags = { "window-rules:dyn-home*", "window-rules:static-barrier*", "window-rules:dyn-absent-after-static*" },
  })
  H.assert_eq(#env.calls.dispatches, 1)
end)

H.test("R19: every required capability is checked and named; hl.dsp.window.center is optional", function()
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "st", name = "Static", match = { class = "^st$" }, workspace = { type = "id", id = 1 } },
      {
        id = "dy",
        name = "Dynamic",
        match = { class = "^dy$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
        layout = "float",
        position = { type = "center" },
      },
    }, json.array_mt),
  }

  local function remove_path(path)
    local cur = _G
    local parts = {}
    for seg in path:gmatch("[^%.]+") do
      parts[#parts + 1] = seg
    end
    for i = 1, #parts - 1 do
      cur = cur[parts[i]]
    end
    cur[parts[#parts]] = nil
  end

  -- Missing static capability o.window fails load with no rules registered.
  make_env()
  remove_path("o.window")
  with_temp_rules(doc, function(path)
    H.assert_false(loader.load(path))
  end)
  local desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(desc.errors[1].code, "capability-missing")
  H.assert_true(desc.errors[1].detail:find("o.window", 1, true) ~= nil)

  -- Missing any dynamic capability keeps static rules and names the missing path.
  for i = 1, #loader.required_api do
    local req = loader.required_api[i]
    local env = make_env()
    remove_path(req)
    with_temp_rules(doc, function(path)
      H.assert_true(loader.load(path))
    end)
    H.assert_eq(#env.calls.window_rules, 2)
    H.assert_eq(#env.calls.subscriptions, 0)
    desc = decode_describe()
    H.assert_eq(desc.dynamic, 0)
    H.assert_eq(desc.errors[1].code, "capability-missing")
    H.assert_true(desc.errors[1].detail:find(req, 1, true) ~= nil, "detail must name " .. req)
  end

  -- Optional hl.dsp.window.center absent: dynamic rules still load, center is skipped cleanly.
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [12] = { id = 12, monitor = mon } },
  })
  _G.hl.dsp.window.center = nil
  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(desc.dynamic, 1)
  H.assert_eq(#desc.errors, 0)
  env.calls.subscriptions[1].cb({
    address = "0x501",
    class = "dy",
    pid = 1,
    floating = true,
    workspace = { id = 1 },
    tags = { "window-rules:dy*" },
  })
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
end)

H.test("R20: backup fallback on invalid primary and describe() counters + api", function()
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [12] = { id = 12, monitor = mon } },
  })
  local valid_bak = json.encode({
    version = 1,
    revision = 4,
    rules = setmetatable({
      { id = "st", name = "Static", match = { class = "^st$" }, workspace = { type = "id", id = 1 } },
      {
        id = "dy",
        name = "Dyn",
        match = { class = "^dy$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
      },
    }, json.array_mt),
  })

  local function with_primary_and_bak(primary_content, bak_content, fn)
    local path = write_temp_file(primary_content)
    local bak_path = path .. ".bak"
    if bak_content ~= nil then
      local f = assert(io.open(bak_path, "wb"))
      f:write(bak_content)
      f:close()
    end
    local ok, err = pcall(fn, path, bak_path)
    os.remove(path)
    os.remove(bak_path)
    if not ok then
      error(err, 0)
    end
  end

  -- Invalid JSON primary + valid .bak -> loads backup and records using-backup with detail "invalid-json".
  with_primary_and_bak("{broken", valid_bak, function(path)
    H.assert_true(loader.load(path))
  end)
  local desc = decode_describe()
  H.assert_eq(loader.api_version, 1)
  H.assert_eq(desc.api, 1)
  H.assert_eq(desc.revision, 4)
  H.assert_eq(desc.rules, 2)
  H.assert_eq(desc.dynamic, 1)
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].code, "using-backup")
  H.assert_eq(desc.errors[1].detail, "invalid-json")
  H.assert_eq(desc.errors[1].id, json.null)
  H.assert_eq(desc.errors[1].index, json.null)

  -- Unsupported version primary + valid .bak -> detail is "unsupported-version".
  with_primary_and_bak('{"version":2,"rules":[]}', valid_bak, function(path)
    H.assert_true(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(desc.rules, 2)
  H.assert_eq(desc.errors[1].code, "using-backup")
  H.assert_eq(desc.errors[1].detail, "unsupported-version")

  -- Invalid primary + invalid .bak -> zero rules and original error code.
  with_primary_and_bak("{broken", "{also broken", function(path)
    H.assert_false(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].code, "invalid-json")

  -- Missing primary with .bak present -> missing file does not load backup.
  local missing_path = os.tmpname()
  os.remove(missing_path)
  local bf = assert(io.open(missing_path .. ".bak", "wb"))
  bf:write(valid_bak)
  bf:close()
  local ok_miss, err_miss = pcall(function()
    H.assert_true(loader.load(missing_path))
  end)
  os.remove(missing_path .. ".bak")
  H.assert_true(ok_miss, err_miss)
  desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(#desc.errors, 0)

  -- Counters: opened, matched, moved.
  with_temp_rules(valid_bak, function(path)
    H.assert_true(loader.load(path))
  end)
  local cb = env.calls.subscriptions[#env.calls.subscriptions].cb
  -- Untagged window: opened=1, matched=0, moved=0.
  cb({ address = "0x601", class = "other", pid = 1, workspace = { id = 1 }, tags = {} })
  -- Static-tagged window: opened=2, matched=1, moved=0.
  cb({ address = "0x602", class = "st", pid = 2, workspace = { id = 1 }, tags = { "window-rules:st*" } })
  -- Dynamic-tagged window: opened=3, matched=2, moved=1.
  cb({ address = "0x603", class = "dy", pid = 3, workspace = { id = 1 }, tags = { "window-rules:dy*" } })
  desc = decode_describe()
  H.assert_eq(desc.counters.opened, 3)
  H.assert_eq(desc.counters.matched, 2)
  H.assert_eq(desc.counters.moved, 1)
end)

H.test("R09: validation and runtime errors include 1-based rule index", function()
  local env = make_env()
  H.assert_true(loader.register_resolver("boom", {
    label = "Boom",
    resolve = function()
      error("kaboom")
    end,
  }))
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "dup", name = "First", match = { class = "^a$" } },
      { id = "dup", name = "Second", match = { class = "^b$" } },
      { name = "No Id 1", match = { class = "^c$" } },
      { name = "No Id 2", match = { class = "^d$" } },
      {
        id = "fail-rt",
        name = "Fail RT",
        match = { class = "^e$" },
        workspace = { type = "resolver", resolver = "boom", arg = 1 },
      },
      {
        id = "miss-rt",
        name = "Miss RT",
        match = { class = "^f$" },
        workspace = { type = "resolver", resolver = "not-here", arg = 1 },
      },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  env.calls.subscriptions[1].cb({
    address = "0x701",
    class = "e",
    pid = 1,
    workspace = { id = 1 },
    tags = { "window-rules:fail-rt*" },
  })

  local desc = decode_describe()
  H.assert_eq(#desc.errors, 5)

  H.assert_eq(desc.errors[1].id, "dup")
  H.assert_eq(desc.errors[1].index, 2)
  H.assert_eq(desc.errors[1].code, "duplicate-id")

  H.assert_eq(desc.errors[2].id, json.null)
  H.assert_eq(desc.errors[2].index, 3)
  H.assert_eq(desc.errors[2].code, "invalid-id")

  H.assert_eq(desc.errors[3].id, json.null)
  H.assert_eq(desc.errors[3].index, 4)
  H.assert_eq(desc.errors[3].code, "invalid-id")

  H.assert_eq(desc.errors[4].id, "miss-rt")
  H.assert_eq(desc.errors[4].index, 6)
  H.assert_eq(desc.errors[4].code, "resolver-missing")

  H.assert_eq(desc.errors[5].id, "fail-rt")
  H.assert_eq(desc.errors[5].index, 5)
  H.assert_eq(desc.errors[5].code, "resolver-failed")
end)

H.test("R21: monitor-slot workspace on another monitor, monitorless position fallback, file-unreadable, MAX_ERRORS cap, bad register_resolver and describe() fallback", function()
  -- 1. monitor-slot workspace already exists on another monitor -> workspace.move before window.move.
  local dp1 = { name = "DP-1", block = 1, x = 1920, y = 0 }
  local edp1 = { name = "eDP-1", block = 0, x = 0, y = 0 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = dp1, ["DP-1"] = dp1, ["eDP-1"] = edp1 },
    workspaces = {
      [12] = { id = 12, monitor = edp1 }, -- belongs to DP-1 block, sitting on eDP-1
      [25] = { id = 25, monitor = dp1 },
    },
  })
  H.assert_true(loader.register_resolver("ws-only", {
    label = "Workspace only",
    resolve = function()
      return { workspace = 25 } -- no monitor field: position must fall back to workspace monitor
    end,
  }))
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "slot-other-mon",
        name = "Slot Other Mon",
        match = { class = "^m$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
      },
      {
        id = "no-mon-pos",
        name = "No Mon Pos",
        match = { class = "^n$" },
        workspace = { type = "resolver", resolver = "ws-only", arg = 1 },
        layout = "float",
        position = { type = "at", x = 30, y = 40 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)
  local cb = env.calls.subscriptions[1].cb
  cb({ address = "0x801", class = "m", pid = 1, workspace = { id = 1 }, tags = { "window-rules:slot-other-mon*" } })
  H.assert_eq(env.calls.dispatches[1].kind, "workspace.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "12")
  H.assert_eq(env.calls.dispatches[1].arg.monitor, "DP-1")
  H.assert_eq(env.calls.dispatches[2].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].arg.workspace, "12")

  -- Position fallback when target.monitor == nil uses destination workspace's monitor origin (1920, 0).
  cb({ address = "0x802", class = "n", pid = 2, floating = true, workspace = { id = 1 }, tags = { "window-rules:no-mon-pos*" } })
  H.assert_eq(env.calls.dispatches[3].kind, "window.move")
  H.assert_eq(env.calls.dispatches[4].kind, "window.move")
  H.assert_eq(env.calls.dispatches[4].arg.x, 1950)
  H.assert_eq(env.calls.dispatches[4].arg.y, 40)

  -- 2. file-unreadable (a directory path fails f:read with EISDIR regardless of user privileges).
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  H.assert_true(os.execute("mkdir -p '" .. tmp_dir .. "'"))
  local ok_dir, err_dir = pcall(function()
    H.assert_false(loader.load(tmp_dir))
  end)
  os.execute("rm -rf '" .. tmp_dir .. "'")
  H.assert_true(ok_dir, err_dir)
  local desc = decode_describe()
  H.assert_eq(desc.rules, 0)
  H.assert_eq(desc.errors[1].code, "file-unreadable")

  -- 3. MAX_ERRORS cap (200): 1 capability-missing + 200 invalid rules -> capped at 200.
  make_env()
  _G.hl.dsp.focus = nil
  local many = setmetatable({}, json.array_mt)
  for i = 1, 200 do
    many[i] = { id = "bad-" .. i, name = "Bad " .. i, match = { class = "^x$" }, opacity = 9 }
  end
  with_temp_rules({ version = 1, rules = many }, function(path)
    H.assert_true(loader.load(path))
  end)
  desc = decode_describe()
  H.assert_eq(#desc.errors, 200)
  H.assert_eq(desc.errors[1].code, "capability-missing")

  -- 4. register_resolver with bad arguments returns false without raising; valid replacement works.
  H.assert_false(loader.register_resolver("", { resolve = function() end }))
  H.assert_false(loader.register_resolver("Upper", { resolve = function() end }))
  H.assert_false(loader.register_resolver(string.rep("a", 33), { resolve = function() end }))
  H.assert_false(loader.register_resolver(123, { resolve = function() end }))
  H.assert_false(loader.register_resolver("valid-name", nil))
  H.assert_false(loader.register_resolver("valid-name", { label = "No fn" }))
  H.assert_false(loader.register_resolver("valid-name", { resolve = "not-a-fn" }))
  H.assert_true(loader.register_resolver("ws-only", { label = "Replaced", resolve = function() return nil end }))

  -- 5. describe() fallback when describe_impl raises returns valid encoded empty state.
  local real_sort = table.sort
  local tripped = false
  table.sort = function(...)
    if not tripped then
      tripped = true
      error("simulated describe failure")
    end
    return real_sort(...)
  end
  local ok_fb, raw_fb = pcall(loader.describe)
  table.sort = real_sort
  H.assert_true(ok_fb)
  H.assert_true(tripped, "test must trigger describe() fallback path")
  local fb, fb_err = json.decode(raw_fb)
  H.assert_nil(fb_err)
  H.assert_eq(fb.loaded, true)
  H.assert_eq(fb.api, 1)
  H.assert_eq(fb.loaderVersion, "unknown")
  H.assert_eq(fb.schema, 1)
  H.assert_eq(fb.revision, 0)
  H.assert_eq(fb.rules, 0)
  H.assert_eq(fb.dynamic, 0)
  H.assert_deep_eq(fb.counters, { opened = 0, matched = 0, moved = 0 })
  H.assert_eq(#fb.resolvers, 0)
  H.assert_eq(#fb.errors, 0)
end)

H.test("WP-15.1: static id and special fallbacks use static semantics without sibling filter", function()
  local env = make_env({ monitors = {}, workspaces = {} })
  H.assert_true(loader.register_resolver("wp15-away", {
    label = "Away",
    resolve = function()
      return nil
    end,
  }))
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "static-id-follow",
        name = "Static ID Follow",
        match = { class = "^sid$" },
        workspace = { type = "id", id = 5 },
        follow = true,
      },
      {
        id = "static-sp-center",
        name = "Static Special Center",
        match = { class = "^ssp$" },
        workspace = { type = "special", name = "scratchpad" },
        follow = false,
        layout = "float",
        position = { type = "center" },
      },
      {
        id = "dyn-decline",
        name = "Dyn Decline",
        match = { class = "^s(id|sp)$" },
        workspace = { type = "resolver", resolver = "wp15-away", arg = 1 },
      },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  local cb = env.calls.subscriptions[1].cb

  -- Static id fallback with an off-target sibling of the same (pid, class) still moves with static follow.
  env.set_windows({
    { address = "0x900", pid = 900, class = "sid", workspace = { id = 2 } },
    { address = "0x901", pid = 900, class = "sid", workspace = { id = 1 } },
  })
  cb({
    address = "0x901",
    class = "sid",
    pid = 900,
    workspace = { id = 1, name = "1" },
    tags = { "window-rules:static-id-follow*", "window-rules:dyn-decline*" },
  })
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "5")
  H.assert_eq(env.calls.dispatches[1].arg.follow, true)
  H.assert_eq(decode_describe().counters.moved, 1)

  -- Static id fallback with an on-target sibling keeps static rule's follow = true (not forced silent).
  env.set_windows({
    { address = "0x900", pid = 900, class = "sid", workspace = { id = 5 } },
    { address = "0x902", pid = 900, class = "sid", workspace = { id = 1 } },
  })
  cb({
    address = "0x902",
    class = "sid",
    pid = 900,
    workspace = { id = 1, name = "1" },
    tags = { "window-rules:static-id-follow*", "window-rules:dyn-decline*" },
  })
  H.assert_eq(#env.calls.dispatches, 2)
  H.assert_eq(env.calls.dispatches[2].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].arg.workspace, "5")
  H.assert_eq(env.calls.dispatches[2].arg.follow, true)
  H.assert_eq(decode_describe().counters.moved, 2)

  -- Static id fallback skipped when already on target workspace.
  cb({
    address = "0x903",
    class = "sid",
    pid = 900,
    workspace = { id = 5, name = "5" },
    tags = { "window-rules:static-id-follow*", "window-rules:dyn-decline*" },
  })
  H.assert_eq(#env.calls.dispatches, 2)
  H.assert_eq(decode_describe().counters.moved, 2)

  -- Static special fallback moves with static follow, ignores off-target sibling, reapplies position and increments moved.
  env.set_windows({
    { address = "0x910", pid = 910, class = "ssp", workspace = { id = 2, name = "2" } },
    { address = "0x911", pid = 910, class = "ssp", workspace = { id = 1, name = "1" } },
  })
  cb({
    address = "0x911",
    class = "ssp",
    pid = 910,
    floating = true,
    workspace = { id = 1, name = "1" },
    tags = { "window-rules:static-sp-center*", "window-rules:dyn-decline*" },
  })
  H.assert_eq(#env.calls.dispatches, 4)
  H.assert_eq(env.calls.dispatches[3].kind, "window.move")
  H.assert_eq(env.calls.dispatches[3].arg.workspace, "special:scratchpad")
  H.assert_eq(env.calls.dispatches[3].arg.follow, false)
  H.assert_eq(env.calls.dispatches[4].kind, "window.center")
  H.assert_eq(env.calls.dispatches[4].arg.window, "address:0x911")
  H.assert_eq(decode_describe().counters.moved, 3)

  -- Static special fallback skipped when already on that special workspace; moved counter unchanged.
  cb({
    address = "0x912",
    class = "ssp",
    pid = 910,
    floating = true,
    workspace = { id = -99, name = "special:scratchpad", special = true },
    tags = { "window-rules:static-sp-center*", "window-rules:dyn-decline*" },
  })
  H.assert_eq(#env.calls.dispatches, 4)
  H.assert_eq(decode_describe().counters.moved, 3)
end)

H.test("WP-15.2: failing, garbage and missing resolvers record error and continue candidate walk", function()
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local env = make_env({
    monitors = { ["desc:Dock"] = mon, ["DP-1"] = mon },
    workspaces = { [14] = { id = 14, monitor = mon } },
  })
  H.assert_true(loader.register_resolver("wp15-boom", {
    label = "Boom",
    resolve = function()
      error("resolver exploded")
    end,
  }))
  H.assert_true(loader.register_resolver("wp15-garbage", {
    label = "Garbage",
    resolve = function()
      return "not-a-table"
    end,
  }))
  H.assert_true(loader.register_resolver("wp15-ok", {
    label = "OK",
    resolve = function()
      return { workspace = 14, monitor = "DP-1" }
    end,
  }))

  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "st-id", name = "Static ID", match = { class = "^a$" }, workspace = { type = "id", id = 5 }, follow = true },
      { id = "st-sp", name = "Static SP", match = { class = "^b$" }, workspace = { type = "special", name = "notes" }, follow = false },
      { id = "dy-ok", name = "Dyn OK", match = { class = "^c$" }, workspace = { type = "resolver", resolver = "wp15-ok", arg = 1 } },
      { id = "dy-boom", name = "Dyn Boom", match = { class = "^[ac]$" }, workspace = { type = "resolver", resolver = "wp15-boom", arg = 1 } },
      { id = "dy-bad", name = "Dyn Bad", match = { class = "^b$" }, workspace = { type = "resolver", resolver = "wp15-garbage", arg = 1 } },
      { id = "dy-miss", name = "Dyn Miss", match = { class = "^[ac]$" }, workspace = { type = "resolver", resolver = "wp15-missing", arg = 1 } },
    }, json.array_mt),
  }
  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  local cb = env.calls.subscriptions[1].cb

  -- Raising resolver over an earlier static id -> records resolver-failed and falls back to ws 5.
  cb({ address = "0xa1", class = "a", pid = 1, workspace = { id = 1 }, tags = { "window-rules:st-id*", "window-rules:dy-boom*" } })
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "5")
  H.assert_eq(env.calls.dispatches[1].arg.follow, true)

  -- Garbage resolver over an earlier static special -> records resolver-failed and falls back to special:notes.
  cb({ address = "0xa2", class = "b", pid = 2, workspace = { id = 1, name = "1" }, tags = { "window-rules:st-sp*", "window-rules:dy-bad*" } })
  H.assert_eq(#env.calls.dispatches, 2)
  H.assert_eq(env.calls.dispatches[2].kind, "window.move")
  H.assert_eq(env.calls.dispatches[2].arg.workspace, "special:notes")
  H.assert_eq(env.calls.dispatches[2].arg.follow, false)

  -- Raising resolver over an earlier dynamic rule -> falls back to earlier dynamic (ws 14).
  cb({ address = "0xa3", class = "c", pid = 3, workspace = { id = 1 }, tags = { "window-rules:dy-ok*", "window-rules:dy-boom*" } })
  H.assert_eq(#env.calls.dispatches, 3)
  H.assert_eq(env.calls.dispatches[3].kind, "window.move")
  H.assert_eq(env.calls.dispatches[3].arg.workspace, "14")

  -- Missing resolver over an earlier static id -> records resolver-missing and falls back to ws 5.
  cb({ address = "0xa4", class = "a", pid = 4, workspace = { id = 1 }, tags = { "window-rules:st-id*", "window-rules:dy-miss*" } })
  H.assert_eq(#env.calls.dispatches, 4)
  H.assert_eq(env.calls.dispatches[4].kind, "window.move")
  H.assert_eq(env.calls.dispatches[4].arg.workspace, "5")

  -- Missing resolver over an earlier dynamic rule -> falls back to ws 14.
  cb({ address = "0xa5", class = "c", pid = 5, workspace = { id = 1 }, tags = { "window-rules:dy-ok*", "window-rules:dy-miss*" } })
  H.assert_eq(#env.calls.dispatches, 5)
  H.assert_eq(env.calls.dispatches[5].kind, "window.move")
  H.assert_eq(env.calls.dispatches[5].arg.workspace, "14")

  local desc = decode_describe()
  H.assert_eq(desc.counters.moved, 5)
  local by_id = {}
  for i = 1, #desc.errors do
    by_id[desc.errors[i].id] = desc.errors[i]
  end
  H.assert_eq(by_id["dy-miss"].code, "resolver-missing")
  H.assert_eq(by_id["dy-miss"].index, 6)
  H.assert_eq(by_id["dy-boom"].code, "resolver-failed")
  H.assert_eq(by_id["dy-boom"].index, 4)
  H.assert_eq(by_id["dy-bad"].code, "resolver-failed")
  H.assert_eq(by_id["dy-bad"].index, 5)
end)

H.test("WP-15.3: o.window failure on one rule records register-failed and keeps remaining rules and subscription", function()
  local mon = { name = "DP-1", block = 1, x = 0, y = 0 }
  local env = make_env({
    monitors = { ["desc:Vendor Model Serial"] = mon, ["DP-1"] = mon },
    workspaces = { [13] = { id = 13, monitor = mon } },
    on_window = function(_match, effects)
      if effects.name == "window-rules/r2" then
        error("unsupported effect: opacity")
      end
    end,
  })
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "r1", name = "Rule 1", match = { class = "^r1$" }, workspace = { type = "id", id = 2 } },
      {
        id = "r2",
        name = "Rule 2",
        match = { class = "^r2$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 2 },
        opacity = 0.9,
      },
      {
        id = "r3",
        name = "Rule 3",
        match = { class = "^r3$" },
        workspace = { type = "monitor-slot", monitor = "desc:Vendor Model Serial", slot = 3 },
      },
      { id = "r4", name = "Rule 4", match = { class = "^r4$" }, workspace = { type = "id", id = 4 } },
    }, json.array_mt),
  }

  with_temp_rules(doc, function(path)
    H.assert_true(loader.load(path))
  end)

  H.assert_eq(#env.calls.window_rules, 3)
  H.assert_eq(env.calls.window_rules[1].effects.name, "window-rules/r1")
  H.assert_eq(env.calls.window_rules[2].effects.name, "window-rules/r3")
  H.assert_eq(env.calls.window_rules[3].effects.name, "window-rules/r4")
  H.assert_eq(#env.calls.subscriptions, 1, "window.open subscription must still be made for registered dynamic rule")

  local desc = decode_describe()
  H.assert_eq(desc.rules, 3)
  H.assert_eq(desc.dynamic, 1)
  H.assert_eq(#desc.errors, 1)
  H.assert_eq(desc.errors[1].id, "r2")
  H.assert_eq(desc.errors[1].index, 2)
  H.assert_eq(desc.errors[1].code, "register-failed")
  H.assert_true(desc.errors[1].detail:find("unsupported effect: opacity", 1, true) ~= nil)

  local cb = env.calls.subscriptions[1].cb
  -- Failed rule r2 is not in candidate tables and does not trigger a move.
  cb({ address = "0xb1", class = "r2", pid = 1, workspace = { id = 1 }, tags = { "window-rules:r2*" } })
  H.assert_eq(#env.calls.dispatches, 0)

  -- Registered dynamic rule r3 works normally.
  cb({ address = "0xb2", class = "r3", pid = 2, workspace = { id = 1 }, tags = { "window-rules:r3*" } })
  H.assert_eq(#env.calls.dispatches, 1)
  H.assert_eq(env.calls.dispatches[1].kind, "window.move")
  H.assert_eq(env.calls.dispatches[1].arg.workspace, "13")
end)

H.finish("loader_test")
