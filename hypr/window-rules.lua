-- Hyprland Lua loader for io.github.ltecosta.window-rules (Lua 5.4+).

local M = {
  api_version = 1,
}

local MAX_BYTES = 1048576
local MAX_ERRORS = 200
local PLUGIN_ID = "io.github.ltecosta.window-rules"

local STATIC_CAPABILITIES = {
  "o.window",
}

local DYNAMIC_CAPABILITIES = {
  "o.workspaces.workspace_id",
  "o.workspaces.focus",
  "hl.on",
  "hl.dispatch",
  "hl.dsp.focus",
  "hl.dsp.window.move",
  "hl.dsp.workspace.move",
  "hl.get_workspace",
  "hl.get_monitor",
  "hl.get_windows",
  "hl.get_window",
  "hl.get_active_window",
  "hl.get_active_monitor",
  "hl.get_active_workspace",
}

M.required_api = DYNAMIC_CAPABILITIES

M.required_fields = {
  window = {
    "address",
    "class",
    "floating",
    "focus_history_id",
    "monitor",
    "pid",
    "tags",
    "workspace",
  },
  monitor = {
    "active_workspace",
    "name",
    "x",
    "y",
  },
  workspace = {
    "id",
    "monitor",
    "name",
    "special",
    "visible",
  },
}

local function script_dir()
  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return source:match("^(.+)/[^/]+$") or "."
end

local BASE_DIR = script_dir()
local json = dofile(BASE_DIR .. "/json.lua")
local schema = dofile(BASE_DIR .. "/schema.lua")

local function read_loader_version()
  local f = io.open(BASE_DIR .. "/../manifest.json", "rb")
  if not f then
    return "unknown"
  end
  local content = f:read(MAX_BYTES)
  f:close()
  if type(content) ~= "string" then
    return "unknown"
  end
  local ok, manifest = pcall(json.decode, content)
  if ok and type(manifest) == "table" and type(manifest.version) == "string" and manifest.version ~= "" then
    return manifest.version
  end
  return "unknown"
end

local LOADER_VERSION = read_loader_version()

local resolvers = {}
local subscription = nil
local rules_by_id = {}

local function new_state()
  return {
    revision = 0,
    rules_count = 0,
    dynamic_count = 0,
    counters = {
      opened = 0,
      matched = 0,
      moved = 0,
    },
    errors = {},
  }
end

local state = new_state()

local function default_rules_path()
  -- A relative XDG_STATE_HOME is invalid by the XDG spec and ignored, as Model.js does.
  local state_home = os.getenv("XDG_STATE_HOME")
  if not state_home or state_home:sub(1, 1) ~= "/" then
    state_home = (os.getenv("HOME") or "") .. "/.local/state"
  end
  return state_home .. "/omarchy/" .. PLUGIN_ID .. "/rules.json"
end

local function normalize_id(id)
  return (type(id) == "string" and id ~= "") and id or json.null
end

local function normalize_index(index)
  if type(index) == "number" then
    local n = math.tointeger(index)
    if n and n >= 1 then
      return n
    end
  end
  return json.null
end

local function has_error(id, code, index)
  local target_id = normalize_id(id)
  local target_index = normalize_index(index)
  for i = 1, #state.errors do
    local e = state.errors[i]
    if e.code == code and e.id == target_id and e.index == target_index then
      return true
    end
  end
  return false
end

-- Records one error per (rule id, rule index, code): a resolver that fails on
-- every window open reports once instead of filling the list, while separate
-- invalid rules keep their own entries with their 1-based index.
local function add_error(id, code, detail, index)
  if #state.errors >= MAX_ERRORS or has_error(id, code, index) then
    return
  end
  state.errors[#state.errors + 1] = {
    id = normalize_id(id),
    index = normalize_index(index),
    code = code,
    detail = tostring(detail or code),
  }
end

local function remove_subscription()
  if subscription then
    local sub = subscription
    subscription = nil
    pcall(function()
      if type(sub.remove) == "function" then
        sub:remove()
      end
    end)
  end
end

local function has_callable_path(path)
  local current = _G
  for segment in path:gmatch("[^%.]+") do
    local t = type(current)
    if t ~= "table" and t ~= "userdata" then
      return false
    end
    local ok, next_val = pcall(function()
      return current[segment]
    end)
    if not ok or next_val == nil then
      return false
    end
    current = next_val
  end
  return type(current) == "function"
end

local function check_capabilities(paths)
  for i = 1, #paths do
    local path = paths[i]
    if not has_callable_path(path) then
      return false, path
    end
  end
  return true, nil
end

local function build_effects(rule, allow_dynamic)
  local effects = {
    name = "window-rules/" .. rule.id,
    tag = "+window-rules:" .. rule.id,
  }

  local ws = rule.workspace
  if ws.type == "id" then
    local spec = tostring(ws.id)
    if not rule.follow then
      spec = spec .. " silent"
    end
    effects.workspace = spec
  elseif ws.type == "special" then
    local spec = "special:" .. ws.name
    if not rule.follow then
      spec = spec .. " silent"
    end
    effects.workspace = spec
  elseif allow_dynamic and (ws.type == "monitor-slot" or ws.type == "resolver") then
    -- Cancel any earlier static rule's workspace effect before window.open runs.
    effects.workspace = "unset"
  end

  if rule.layout == "tile" then
    effects.tile = true
  elseif rule.layout == "float" then
    effects.float = true
  end

  if rule.size ~= nil then
    effects.size = { rule.size[1], rule.size[2] }
  end

  if rule.position.type == "center" then
    effects.center = true
  elseif rule.position.type == "at" then
    effects.move = { rule.position.x, rule.position.y }
  end

  if rule.monitor ~= nil then
    effects.monitor = rule.monitor
  end

  if rule.fullscreen then
    effects.fullscreen = true
  end
  if rule.maximize then
    effects.maximize = true
  end
  if rule.pin then
    effects.pin = true
  end
  if rule.noInitialFocus then
    effects.no_initial_focus = true
  end

  if rule.opacity ~= nil then
    effects.opacity = string.format("%g", rule.opacity)
  end

  return effects
end

local function is_on_visible_workspace(window)
  return window ~= nil and window.workspace ~= nil and window.workspace.visible == true
end

-- The window focused before the one being moved. Hyprland may already have
-- focused the new window when window.open runs; then the previous one is the
-- other window on a visible workspace with the lowest focus history id
-- (open special workspaces included; hidden ones are skipped).
local function previous_window(moving_address)
  local hl_api = _G.hl
  local active = hl_api.get_active_window and hl_api.get_active_window()
  if active and active.address ~= moving_address and is_on_visible_workspace(active) then
    return active
  end
  local list = hl_api.get_windows and hl_api.get_windows()
  if type(list) ~= "table" then
    return nil
  end
  local best = nil
  for i = 1, #list do
    local candidate = list[i]
    local history = candidate.focus_history_id
    if candidate.address ~= moving_address and is_on_visible_workspace(candidate)
      and math.type(history) == "integer" and history >= 0
      and (not best or history < best.focus_history_id) then
      best = candidate
    end
  end
  return best
end

-- Remember the focused window, or the focused monitor when it shows no window,
-- and return a function that puts focus back there, along with the monitor
-- focus belongs to. Only a window on a visible workspace counts, an open
-- special workspace such as a drop-down console included: focusing a window on
-- a hidden special workspace would open it. The window's monitor is focused
-- first, so an open special workspace stays on its own monitor.
local function capture_focus(moving_address)
  local hl_api = _G.hl
  local prev_win = previous_window(moving_address)
  local prev_mon = hl_api.get_active_monitor and hl_api.get_active_monitor()
  local prev_addr = nil
  if prev_win and prev_win.address and prev_win.address ~= moving_address
    and is_on_visible_workspace(prev_win) then
    prev_addr = prev_win.address
  end
  local prev_mon_name = prev_mon and prev_mon.name or nil
  local origin_mon_name = (prev_addr and prev_win.monitor and prev_win.monitor.name) or prev_mon_name
  -- Creating the target workspace focuses it, so without a window to return to
  -- the previous regular workspace is shown again.
  local prev_ws = hl_api.get_active_workspace and hl_api.get_active_workspace()
  local prev_ws_id = prev_ws and not prev_ws.special and math.type(prev_ws.id) == "integer"
    and prev_ws.id > 0 and prev_ws.id or nil

  local function restore(current_mon_hint)
    local win = prev_addr and hl_api.get_window and hl_api.get_window("address:" .. prev_addr)
    if win then
      local active_mon = hl_api.get_active_monitor and hl_api.get_active_monitor()
      local cur_mon_name = current_mon_hint or (active_mon and active_mon.name)
      if win.monitor and win.monitor.name and (not cur_mon_name or win.monitor.name ~= cur_mon_name) then
        hl_api.dispatch(hl_api.dsp.focus({ monitor = win.monitor.name }))
      end
      hl_api.dispatch(hl_api.dsp.focus({ window = "address:" .. prev_addr }))
      return
    end
    if prev_mon_name then
      hl_api.dispatch(hl_api.dsp.focus({ monitor = prev_mon_name }))
    end
    if prev_ws_id then
      hl_api.dispatch(hl_api.dsp.focus({ workspace = tostring(prev_ws_id) }))
    end
  end

  return restore, origin_mon_name
end

local function reapply_position(address, target, position, window)
  if not position or position.type == "none" then
    return
  end
  if window ~= nil and window.floating == false then
    return
  end
  local hl_api = _G.hl
  local win_sel = "address:" .. address

  if position.type == "center" then
    if has_callable_path("hl.dsp.window.center") then
      hl_api.dispatch(hl_api.dsp.window.center({ window = win_sel }))
    end
  elseif position.type == "at" then
    local dest_mon = nil
    if target.monitor and hl_api.get_monitor then
      dest_mon = hl_api.get_monitor(target.monitor)
    end
    if not dest_mon and hl_api.get_workspace then
      local dest_ws = hl_api.get_workspace(target.workspace)
      dest_mon = dest_ws and dest_ws.monitor
    end
    if not dest_mon and hl_api.get_window then
      local moved_win = hl_api.get_window(win_sel)
      dest_mon = moved_win and moved_win.monitor
    end

    local ox = (dest_mon and dest_mon.x) or 0
    local oy = (dest_mon and dest_mon.y) or 0
    hl_api.dispatch(hl_api.dsp.window.move({
      x = ox + position.x,
      y = oy + position.y,
      relative = false,
      window = win_sel,
    }))
  end
end

local function move_window_internal(address, target, follow, position, window)
  local hl_api = _G.hl
  local o_api = _G.o
  local ws_id = target.workspace
  local ws_str = tostring(ws_id)
  local restore_focus, origin_mon_name
  if not follow then
    restore_focus, origin_mon_name = capture_focus(address)
  end

  local existing = hl_api.get_workspace and hl_api.get_workspace(ws_id)
  local created = (existing == nil)

  -- Remember the regular workspace the target monitor showed before creating a
  -- workspace on it (its own monitor when the target names none), so a silent
  -- move leaves that monitor showing it, on another monitor or under an open
  -- special workspace such as a drop-down console on the same one.
  local dest_mon_name = target.monitor or origin_mon_name
  local dest_prev_ws_id = nil
  if not follow and created and dest_mon_name then
    local dest_mon = hl_api.get_monitor and hl_api.get_monitor(dest_mon_name)
    local dest_ws = dest_mon and dest_mon.active_workspace
    if dest_ws and not dest_ws.special and math.type(dest_ws.id) == "integer"
      and dest_ws.id > 0 and dest_ws.id ~= ws_id then
      dest_prev_ws_id = dest_ws.id
    end
  end

  if created then
    if target.slot and target.monitor and o_api and o_api.workspaces
      and type(o_api.workspaces.focus) == "function" then
      local action = o_api.workspaces.focus(target.slot, target.monitor)
      if type(action) == "function" then
        action()
      end
    else
      if target.monitor then
        hl_api.dispatch(hl_api.dsp.focus({ monitor = target.monitor }))
      end
      hl_api.dispatch(hl_api.dsp.focus({ workspace = ws_str }))
    end
  elseif target.monitor and (not existing.monitor or existing.monitor.name ~= target.monitor) then
    hl_api.dispatch(hl_api.dsp.workspace.move({
      workspace = ws_str,
      monitor = target.monitor,
    }))
  end

  hl_api.dispatch(hl_api.dsp.window.move({
    workspace = ws_str,
    follow = follow == true,
    window = "address:" .. address,
  }))

  if not follow and created then
    local switched_mon = nil
    if dest_prev_ws_id then
      local active_mon = hl_api.get_active_monitor and hl_api.get_active_monitor()
      if not active_mon or active_mon.name ~= dest_mon_name then
        hl_api.dispatch(hl_api.dsp.focus({ monitor = dest_mon_name }))
      end
      hl_api.dispatch(hl_api.dsp.focus({ workspace = tostring(dest_prev_ws_id) }))
      switched_mon = dest_mon_name
    end
    if restore_focus then
      restore_focus(switched_mon)
    end
  end

  reapply_position(address, target, position, window)
end

-- Returns (has_sibling, sibling_on_target) among windows sharing (pid, class)
-- with a different address.
local function inspect_siblings(window, target_ws_id)
  local hl_api = _G.hl
  if type(hl_api.get_windows) ~= "function" or window.pid == nil then
    return false, false
  end
  local list = hl_api.get_windows()
  if type(list) ~= "table" then
    return false, false
  end
  local has_sibling = false
  local on_target = false
  for i = 1, #list do
    local other = list[i]
    if other.pid == window.pid and other.class == window.class and other.address ~= window.address then
      has_sibling = true
      if other.workspace and other.workspace.id == target_ws_id then
        on_target = true
        break
      end
    end
  end
  return has_sibling, on_target
end

-- Resolves a dynamic target. Returns a target table, or nil when the candidate
-- declines quietly or records an error (caller continues the candidate walk).
local function resolve_target(rule, index, window)
  local hl_api = _G.hl
  local o_api = _G.o
  local ws = rule.workspace

  if ws.type == "monitor-slot" then
    if type(hl_api.get_monitor) ~= "function" then
      return nil
    end
    local monitor = hl_api.get_monitor(ws.monitor)
    if not monitor or not monitor.name then
      return nil
    end
    local id = o_api.workspaces.workspace_id(monitor, ws.slot)
    local int_id = type(id) == "number" and math.tointeger(id) or nil
    if not int_id or int_id < 1 then
      return nil
    end
    return { workspace = int_id, monitor = monitor.name, slot = ws.slot }
  elseif ws.type == "resolver" then
    local entry = resolvers[ws.resolver]
    if not entry then
      add_error(rule.id, "resolver-missing", "resolver not registered: " .. ws.resolver, index)
      return nil
    end
    local ok, res = pcall(entry.resolve, ws.arg, window)
    if not ok then
      add_error(rule.id, "resolver-failed", tostring(res), index)
      return nil
    end
    -- nil declines quietly (no destination right now, such as a missing display).
    if res == nil then
      return nil
    end
    if type(res) ~= "table" then
      add_error(rule.id, "resolver-failed", "resolver did not return a table or nil", index)
      return nil
    end
    local int_id = type(res.workspace) == "number" and math.tointeger(res.workspace) or nil
    if not int_id or int_id < 1 then
      add_error(rule.id, "resolver-failed", "resolver returned an invalid workspace id", index)
      return nil
    end
    if res.monitor ~= nil and (type(res.monitor) ~= "string" or res.monitor == "") then
      add_error(rule.id, "resolver-failed", "resolver returned an invalid monitor name", index)
      return nil
    end
    return { workspace = int_id, monitor = res.monitor }
  end

  return nil
end

local function is_on_target(window, target)
  local ws = window.workspace
  if not ws then
    return false
  end
  if target.special then
    return ws.name == target.workspace
  end
  return ws.id == target.workspace
end

local function handle_window_open(window)
  -- Hyprland passes an HL.Window userdata, not a table; read its fields only.
  if window == nil or type(window.address) ~= "string" or window.address == "" then
    return
  end

  state.counters.opened = state.counters.opened + 1

  local candidates = {}
  local seen = {}
  local has_rule_tag = false
  local tags = window.tags
  if type(tags) == "table" then
    for i = 1, #tags do
      local tag = tags[i]
      if type(tag) == "string" then
        local clean = tag:gsub("%*$", "")
        local id = clean:match("^window%-rules:(.+)$")
        if id then
          has_rule_tag = true
          if not seen[id] then
            seen[id] = true
            local entry = rules_by_id[id]
            if entry then
              candidates[#candidates + 1] = entry
            end
          end
        end
      end
    end
  end

  if has_rule_tag then
    state.counters.matched = state.counters.matched + 1
  end

  if #candidates == 0 then
    return
  end

  table.sort(candidates, function(a, b)
    return a.index > b.index
  end)

  -- Effective position is independent of workspace target: the highest-index
  -- tagged rule whose position.type ~= "none".
  local effective_position = nil
  for i = 1, #candidates do
    local pos = candidates[i].rule.position
    if pos and pos.type ~= "none" then
      effective_position = pos
      break
    end
  end

  -- Target selection: walk tagged rules in index-descending order.
  -- Static target stops (Hyprland already applied it unless a later dynamic
  -- rule's workspace = "unset" cancelled it); dynamic resolves and falls
  -- through to earlier candidates when it declines or fails.
  local winning_rule = nil
  local winning_kind = nil
  local target = nil
  local passed_dynamic = false
  for i = 1, #candidates do
    local candidate = candidates[i]
    if candidate.kind == "static" then
      if not passed_dynamic then
        return
      end
      -- A later dynamic rule declined or failed, and its workspace = "unset"
      -- kept Hyprland from applying this static target: apply it here.
      local ws = candidate.rule.workspace
      winning_rule = candidate.rule
      winning_kind = "static"
      if ws.type == "special" then
        target = { workspace = "special:" .. ws.name, special = true }
      else
        target = { workspace = ws.id }
      end
      break
    elseif candidate.kind == "dynamic" then
      passed_dynamic = true
      local resolved = resolve_target(candidate.rule, candidate.index, window)
      if resolved then
        winning_rule = candidate.rule
        winning_kind = "dynamic"
        target = resolved
        break
      end
    end
  end

  if not winning_rule or not target then
    return
  end

  if is_on_target(window, target) then
    return
  end

  if winning_kind == "static" then
    _G.hl.dispatch(_G.hl.dsp.window.move({
      workspace = tostring(target.workspace),
      follow = winning_rule.follow == true,
      window = "address:" .. window.address,
    }))
    reapply_position(window.address, target, effective_position, window)
    state.counters.moved = state.counters.moved + 1
    return
  end

  local has_sibling, sibling_on_target = inspect_siblings(window, target.workspace)
  if has_sibling and not sibling_on_target then
    return
  end

  local follow = winning_rule.follow and not has_sibling
  move_window_internal(window.address, target, follow, effective_position, window)
  state.counters.moved = state.counters.moved + 1
end

local function on_window_open(window)
  local ok, err = pcall(handle_window_open, window)
  if not ok then
    add_error(json.null, "handler-failed", tostring(err))
  end
end

local function register_resolver_impl(name, spec)
  if type(name) ~= "string" or #name < 1 or #name > 32 or not name:match("^[a-z0-9-]+$") then
    return false
  end
  if type(spec) ~= "table" or type(spec.resolve) ~= "function" then
    return false
  end

  resolvers[name] = {
    name = name,
    label = (type(spec.label) == "string" and spec.label ~= "") and spec.label or name,
    arg_label = (type(spec.arg_label) == "string") and spec.arg_label or "",
    resolve = spec.resolve,
  }
  return true
end

function M.register_resolver(name, spec)
  local ok, res = pcall(register_resolver_impl, name, spec)
  if not ok then
    return false
  end
  return res
end

local function read_and_validate_file(file_path)
  local f, open_err, open_errno = io.open(file_path, "rb")
  if not f then
    if open_errno == 2 or (type(open_err) == "string" and open_err:find("No such file", 1, true)) then
      return false, nil, nil, nil, nil, true
    end
    return false, nil, nil, "file-unreadable", open_err or "cannot open rules file", false
  end

  local content, read_err = f:read(MAX_BYTES + 1)
  f:close()
  if content == nil and read_err ~= nil then
    return false, nil, nil, "file-unreadable", read_err, false
  end

  content = content or ""
  if #content > MAX_BYTES then
    return false, nil, nil, "file-too-large", "rules file exceeds 1 MiB limit", false
  end

  local doc, decode_err = json.decode(content, { max_bytes = MAX_BYTES, max_depth = 64 })
  if doc == nil then
    return false, nil, nil, "invalid-json", decode_err or "invalid JSON", false
  end

  local validation = schema.validate_document(doc)
  if validation.file ~= "ok" then
    return false, nil, nil, validation.file, "invalid rules file: " .. validation.file, false
  end

  return true, doc, validation, nil, nil, false
end

local function load_impl(path)
  remove_subscription()
  rules_by_id = {}
  state = new_state()

  local rules_path = (type(path) == "string" and path ~= "") and path or default_rules_path()
  local ok, doc, validation, err_code, err_detail, is_missing = read_and_validate_file(rules_path)
  if is_missing then
    return true
  end

  if not ok then
    local bak_ok, bak_doc, bak_validation = read_and_validate_file(rules_path .. ".bak")
    if bak_ok then
      doc = bak_doc
      validation = bak_validation
      add_error(json.null, "using-backup", err_code)
    else
      add_error(json.null, err_code, err_detail)
      return false
    end
  end

  state.revision = (doc.revision ~= nil and math.tointeger(doc.revision)) or 0

  local has_static, missing_static = check_capabilities(STATIC_CAPABILITIES)
  if not has_static then
    add_error(json.null, "capability-missing", "missing capability: " .. missing_static)
    return false
  end

  local has_dynamic, missing_dynamic = check_capabilities(DYNAMIC_CAPABILITIES)
  if not has_dynamic then
    add_error(json.null, "capability-missing", "missing capability: " .. missing_dynamic)
  end

  local o_api = _G.o
  for i = 1, #validation.rules do
    local entry = validation.rules[i]
    if entry.status ~= "ok" then
      local raw = doc.rules[i]
      local raw_id = (type(raw) == "table" and type(raw.id) == "string" and raw.id ~= "") and raw.id or json.null
      add_error(raw_id, entry.status, "rule validation failed: " .. entry.status, i)
    else
      local rule = entry.rule
      if rule.enabled then
        local reg_ok, reg_err = pcall(o_api.window, schema.compile_match(rule.match), build_effects(rule, has_dynamic))
        if not reg_ok then
          add_error(rule.id, "register-failed", tostring(reg_err), i)
        else
          state.rules_count = state.rules_count + 1

          local ws_type = rule.workspace.type
          if ws_type == "id" or ws_type == "special" then
            rules_by_id[rule.id] = { index = i, kind = "static", rule = rule }
          elseif ws_type == "monitor-slot" or ws_type == "resolver" then
            if ws_type == "resolver" and not resolvers[rule.workspace.resolver] then
              add_error(rule.id, "resolver-missing", "resolver not registered: " .. rule.workspace.resolver, i)
            end
            if has_dynamic then
              rules_by_id[rule.id] = { index = i, kind = "dynamic", rule = rule }
              state.dynamic_count = state.dynamic_count + 1
            else
              rules_by_id[rule.id] = { index = i, kind = "none", rule = rule }
            end
          else
            rules_by_id[rule.id] = { index = i, kind = "none", rule = rule }
          end
        end
      end
    end
  end

  if has_dynamic and state.dynamic_count > 0 then
    subscription = _G.hl.on("window.open", on_window_open)
  end

  return true
end

function M.load(path)
  local ok, res = pcall(load_impl, path)
  if not ok then
    add_error(json.null, "handler-failed", tostring(res))
    return false
  end
  return res
end

local function build_describe_payload(loader_version, current_state, resolver_list, error_list)
  return {
    loaded = true,
    api = M.api_version,
    loaderVersion = loader_version,
    schema = 1,
    revision = current_state.revision,
    rules = current_state.rules_count,
    dynamic = current_state.dynamic_count,
    counters = {
      opened = current_state.counters.opened,
      matched = current_state.counters.matched,
      moved = current_state.counters.moved,
    },
    resolvers = resolver_list,
    errors = error_list,
  }
end

local function describe_impl()
  local resolver_names = {}
  for name in pairs(resolvers) do
    resolver_names[#resolver_names + 1] = name
  end
  table.sort(resolver_names)

  local resolver_list = setmetatable({}, json.array_mt)
  for i = 1, #resolver_names do
    local r = resolvers[resolver_names[i]]
    resolver_list[i] = {
      name = r.name,
      label = r.label,
      argLabel = r.arg_label,
    }
  end

  local error_list = setmetatable({}, json.array_mt)
  for i = 1, #state.errors do
    local e = state.errors[i]
    error_list[i] = {
      id = e.id,
      index = e.index,
      code = e.code,
      detail = e.detail,
    }
  end

  return json.encode(build_describe_payload(LOADER_VERSION, state, resolver_list, error_list))
end

function M.describe()
  local ok, res = pcall(describe_impl)
  if not ok then
    local fallback_payload = build_describe_payload(
      "unknown",
      new_state(),
      setmetatable({}, json.array_mt),
      setmetatable({}, json.array_mt)
    )
    local ok_fallback, encoded = pcall(json.encode, fallback_payload)
    if ok_fallback then
      return encoded
    end
    return "{}"
  end
  return res
end

local function move_window_impl(address, target, follow)
  if type(address) ~= "string" or address == "" then
    return false
  end
  if type(target) ~= "table" then
    return false
  end
  local ws_id = type(target.workspace) == "number" and math.tointeger(target.workspace) or nil
  if not ws_id or ws_id < 1 then
    return false
  end
  if target.monitor ~= nil and (type(target.monitor) ~= "string" or target.monitor == "") then
    return false
  end
  if target.slot ~= nil then
    local slot = type(target.slot) == "number" and math.tointeger(target.slot) or nil
    if not slot or slot < 1 then
      return false
    end
  end

  local has_dynamic, missing_dynamic = check_capabilities(DYNAMIC_CAPABILITIES)
  if not has_dynamic then
    add_error(json.null, "capability-missing", "missing capability: " .. missing_dynamic)
    return false
  end

  move_window_internal(address, {
    workspace = ws_id,
    monitor = target.monitor,
    slot = target.slot and math.tointeger(target.slot) or nil,
  }, follow ~= false, nil, nil)
  return true
end

function M.move_window(address, target, follow)
  local ok, res = pcall(move_window_impl, address, target, follow)
  if not ok then
    add_error(json.null, "handler-failed", tostring(res))
    return false
  end
  return res
end

_G.window_rules = M

return M
