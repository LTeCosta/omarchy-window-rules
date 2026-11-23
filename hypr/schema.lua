-- Schema validation and normalization for rules.json v1 (Lua 5.4+).

local M = {}

local MAX_RULES = 200
local MAX_REVISION = 9007199254740991
local MAX_ID = 48
local MAX_NAME = 80
local MAX_PATTERN = 256
local MAX_CLASSES = 32
local MAX_WORKSPACE_ID = 9999
local MAX_SPECIAL_NAME = 32
local MAX_RESOLVER_NAME = 32
local MAX_MONITOR = 128
local MAX_SLOT = 10
local MAX_ARG = 99
local MAX_SIZE = 16384
local MAX_POSITION = 16384
local MIN_OPACITY = 0.05
local MAX_OPACITY = 1.0

M.limits = {
  MAX_RULES = MAX_RULES,
  MAX_REVISION = MAX_REVISION,
  MAX_ID = MAX_ID,
  MAX_NAME = MAX_NAME,
  MAX_PATTERN = MAX_PATTERN,
  MAX_CLASSES = MAX_CLASSES,
  MAX_WORKSPACE_ID = MAX_WORKSPACE_ID,
  MAX_SPECIAL_NAME = MAX_SPECIAL_NAME,
  MAX_MONITOR = MAX_MONITOR,
  MAX_SLOT = MAX_SLOT,
  MAX_ARG = MAX_ARG,
  MAX_SIZE = MAX_SIZE,
  MAX_POSITION = MAX_POSITION,
  MIN_OPACITY = MIN_OPACITY,
}

local function is_null(value)
  if value == nil then
    return true
  end
  if type(value) == "table" then
    local mt = getmetatable(value)
    return mt ~= nil and mt.__json_type == "null"
  end
  return false
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local mt = getmetatable(value)
  if mt ~= nil then
    if mt.__json_type == "array" then
      return true
    end
    if mt.__json_type == "null" then
      return false
    end
  end

  local count = 0
  local max_k = 0
  for k in pairs(value) do
    count = count + 1
    if math.type(k) ~= "integer" or k < 1 then
      return false
    end
    if k > max_k then
      max_k = k
    end
  end
  return count > 0 and max_k == count
end

local function is_object(value)
  if type(value) ~= "table" then
    return false
  end
  if is_null(value) or is_array(value) then
    return false
  end
  return true
end

local function as_integer(value)
  if type(value) ~= "number" then
    return nil
  end
  if value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return math.tointeger(value)
end

local function valid_string(value, min_len, max_len)
  if type(value) ~= "string" then
    return false
  end
  local cp_len = utf8.len(value)
  if not cp_len or cp_len < min_len or cp_len > max_len then
    return false
  end
  for i = 1, #value do
    local b = value:byte(i)
    if b <= 0x1F or b == 0x7F then
      return false
    end
  end
  return true
end

local function valid_monitor_desc(value)
  if not valid_string(value, 6, MAX_MONITOR) then
    return false
  end
  return value:sub(1, 5) == "desc:"
end

-- Forbidden-construct scan for RE2 compatibility:
-- rejects lookahead/lookbehind, backreferences (\1-\9, \k<), and JS named groups (?<name>).
local function has_forbidden_regex_construct(pattern)
  local n = #pattern
  local i = 1
  local in_class = false

  while i <= n do
    local c = pattern:sub(i, i)
    if in_class then
      if c == "\\" then
        i = i + 2
      elseif c == "]" then
        in_class = false
        i = i + 1
      else
        i = i + 1
      end
    else
      if c == "\\" then
        local next_c = pattern:sub(i + 1, i + 1)
        if next_c >= "1" and next_c <= "9" then
          return true
        end
        if next_c == "k" and pattern:sub(i + 2, i + 2) == "<" then
          return true
        end
        i = i + 2
      elseif c == "[" then
        in_class = true
        i = i + 1
        if i <= n and pattern:sub(i, i) == "^" then
          i = i + 1
        end
        if i <= n and pattern:sub(i, i) == "]" then
          i = i + 1
        end
      elseif c == "(" and pattern:sub(i + 1, i + 1) == "?" then
        local c3 = pattern:sub(i + 2, i + 2)
        if c3 == "=" or c3 == "!" then
          return true
        end
        if c3 == "<" then
          local c4 = pattern:sub(i + 3, i + 3)
          if c4 == "=" or c4 == "!" or c4:match("^[A-Za-z_]$") then
            return true
          end
        end
        i = i + 2
      else
        i = i + 1
      end
    end
  end

  return false
end

local function valid_id(value)
  if type(value) ~= "string" then
    return false
  end
  if #value < 1 or #value > MAX_ID then
    return false
  end
  return value:match("^[a-z0-9][a-z0-9-]*$") ~= nil
end

local function validate_workspace(ws)
  if ws == nil then
    return { type = "none" }, nil
  end
  if not is_object(ws) then
    return nil, "invalid-workspace"
  end

  local kind = ws.type
  if kind == "none" then
    return { type = "none" }, nil
  elseif kind == "id" then
    local id = as_integer(ws.id)
    if not id or id < 1 or id > MAX_WORKSPACE_ID then
      return nil, "invalid-workspace"
    end
    return { type = "id", id = id }, nil
  elseif kind == "special" then
    if type(ws.name) ~= "string" or #ws.name < 1 or #ws.name > MAX_SPECIAL_NAME or not ws.name:match("^[A-Za-z0-9_-]+$") then
      return nil, "invalid-workspace"
    end
    return { type = "special", name = ws.name }, nil
  elseif kind == "monitor-slot" then
    local slot = as_integer(ws.slot)
    if not valid_monitor_desc(ws.monitor) or not slot or slot < 1 or slot > MAX_SLOT then
      return nil, "invalid-workspace"
    end
    return { type = "monitor-slot", monitor = ws.monitor, slot = slot }, nil
  elseif kind == "resolver" then
    local arg = as_integer(ws.arg)
    if type(ws.resolver) ~= "string" or #ws.resolver < 1 or #ws.resolver > MAX_RESOLVER_NAME
      or not ws.resolver:match("^[a-z0-9-]+$") or not arg or arg < 1 or arg > MAX_ARG then
      return nil, "invalid-workspace"
    end
    return { type = "resolver", resolver = ws.resolver, arg = arg }, nil
  end

  return nil, "invalid-workspace"
end

local function validate_size(size)
  if is_null(size) then
    return nil, nil
  end
  if not is_array(size) or #size ~= 2 then
    return nil, "invalid-size"
  end
  local w = as_integer(size[1])
  local h = as_integer(size[2])
  if not w or not h or w < 1 or w > MAX_SIZE or h < 1 or h > MAX_SIZE then
    return nil, "invalid-size"
  end
  return { w, h }, nil
end

local function validate_position(pos)
  if pos == nil then
    return { type = "none" }, nil
  end
  if not is_object(pos) then
    return nil, "invalid-position"
  end

  local kind = pos.type
  if kind == "none" then
    return { type = "none" }, nil
  elseif kind == "center" then
    return { type = "center" }, nil
  elseif kind == "at" then
    local x = as_integer(pos.x)
    local y = as_integer(pos.y)
    if not x or not y or x < 0 or x > MAX_POSITION or y < 0 or y > MAX_POSITION then
      return nil, "invalid-position"
    end
    return { type = "at", x = x, y = y }, nil
  end

  return nil, "invalid-position"
end

local function validate_flag(value, default)
  if value == nil then
    return default, nil
  end
  if type(value) ~= "boolean" then
    return nil, "invalid-flag"
  end
  return value, nil
end

local function validate_match(raw_match)
  if not is_object(raw_match) then
    return nil, "invalid-class"
  end

  local mode = "regex"
  if raw_match.mode ~= nil then
    if raw_match.mode ~= "apps" and raw_match.mode ~= "regex" then
      return nil, "invalid-class"
    end
    mode = raw_match.mode
  end

  local classes = nil
  local class_pattern = nil
  if mode == "apps" then
    if not is_array(raw_match.classes) or #raw_match.classes < 1 or #raw_match.classes > MAX_CLASSES then
      return nil, "invalid-class"
    end
    classes = {}
    for i = 1, #raw_match.classes do
      local item = raw_match.classes[i]
      if not valid_string(item, 1, MAX_PATTERN) then
        return nil, "invalid-class"
      end
      classes[i] = item
    end
  else
    if not valid_string(raw_match.class, 1, MAX_PATTERN)
      or has_forbidden_regex_construct(raw_match.class) then
      return nil, "invalid-class"
    end
    class_pattern = raw_match.class
  end

  local title_mode = "regex"
  if raw_match.titleMode ~= nil then
    if raw_match.titleMode ~= "exact" and raw_match.titleMode ~= "regex" then
      return nil, "invalid-title"
    end
    title_mode = raw_match.titleMode
  end

  local title = ""
  if raw_match.title ~= nil then
    if not valid_string(raw_match.title, 0, MAX_PATTERN) then
      return nil, "invalid-title"
    end
    if title_mode == "regex" and has_forbidden_regex_construct(raw_match.title) then
      return nil, "invalid-title"
    end
    title = raw_match.title
  end

  local initial, flag_err = validate_flag(raw_match.initial, false)
  if flag_err then
    return nil, flag_err
  end

  if mode == "apps" then
    return {
      mode = "apps",
      classes = classes,
      title = title,
      titleMode = title_mode,
      initial = initial,
    }, nil
  end
  return {
    mode = "regex",
    class = class_pattern,
    title = title,
    titleMode = title_mode,
    initial = initial,
  }, nil
end

local function fail_rule(code)
  return { status = code, warnings = {}, rule = nil }
end

local function validate_rule(raw, seen_ids)
  if not is_object(raw) then
    return fail_rule("invalid-rule")
  end

  if not valid_id(raw.id) then
    return fail_rule("invalid-id")
  end
  if seen_ids[raw.id] then
    return fail_rule("duplicate-id")
  end
  seen_ids[raw.id] = true

  if not valid_string(raw.name, 1, MAX_NAME) then
    return fail_rule("invalid-name")
  end

  local enabled, flag_err = validate_flag(raw.enabled, true)
  if flag_err then
    return fail_rule(flag_err)
  end

  local match, match_err = validate_match(raw.match)
  if match_err then
    return fail_rule(match_err)
  end

  local workspace, ws_err = validate_workspace(raw.workspace)
  if ws_err then
    return fail_rule(ws_err)
  end

  local follow
  follow, flag_err = validate_flag(raw.follow, true)
  if flag_err then
    return fail_rule(flag_err)
  end

  local layout = "default"
  if raw.layout ~= nil then
    if raw.layout ~= "default" and raw.layout ~= "tile" and raw.layout ~= "float" then
      return fail_rule("invalid-layout")
    end
    layout = raw.layout
  end

  local size, size_err = validate_size(raw.size)
  if size_err then
    return fail_rule(size_err)
  end

  local position, pos_err = validate_position(raw.position)
  if pos_err then
    return fail_rule(pos_err)
  end

  local monitor = nil
  if not is_null(raw.monitor) then
    if not valid_monitor_desc(raw.monitor) then
      return fail_rule("invalid-monitor")
    end
    monitor = raw.monitor
  end

  local fullscreen, maximize, pin, no_initial_focus
  fullscreen, flag_err = validate_flag(raw.fullscreen, false)
  if flag_err then
    return fail_rule(flag_err)
  end
  maximize, flag_err = validate_flag(raw.maximize, false)
  if flag_err then
    return fail_rule(flag_err)
  end
  pin, flag_err = validate_flag(raw.pin, false)
  if flag_err then
    return fail_rule(flag_err)
  end
  no_initial_focus, flag_err = validate_flag(raw.noInitialFocus, false)
  if flag_err then
    return fail_rule(flag_err)
  end

  local opacity = nil
  if not is_null(raw.opacity) then
    if type(raw.opacity) ~= "number" or raw.opacity ~= raw.opacity
      or raw.opacity < MIN_OPACITY or raw.opacity > MAX_OPACITY then
      return fail_rule("invalid-opacity")
    end
    opacity = raw.opacity
  end

  if fullscreen and maximize then
    return fail_rule("conflicting-effects")
  end

  local warnings = {}
  if (size ~= nil or position.type ~= "none") and layout ~= "float" then
    warnings[1] = "warn-geometry-not-floating"
  end

  return {
    status = "ok",
    warnings = warnings,
    rule = {
      id = raw.id,
      name = raw.name,
      enabled = enabled,
      match = match,
      workspace = workspace,
      follow = follow,
      layout = layout,
      size = size,
      position = position,
      monitor = monitor,
      fullscreen = fullscreen,
      maximize = maximize,
      pin = pin,
      opacity = opacity,
      noInitialFocus = no_initial_focus,
    },
  }
end

local function escape_regex_literal(value)
  local out = {}
  for i = 1, #value do
    local b = value:byte(i)
    if b < 128 and not (
      (b >= 0x30 and b <= 0x39)
      or (b >= 0x41 and b <= 0x5A)
      or (b >= 0x61 and b <= 0x7A)
      or b == 0x5F
    ) then
      out[i] = "\\" .. value:sub(i, i)
    else
      out[i] = value:sub(i, i)
    end
  end
  return table.concat(out)
end

function M.compile_match(match)
  local mode = match.mode or "regex"
  local title_mode = match.titleMode or "regex"
  local initial = match.initial == true
  local class_key = initial and "initial_class" or "class"
  local title_key = initial and "initial_title" or "title"

  local compiled = {}
  if mode == "apps" then
    local escaped = {}
    for i = 1, #match.classes do
      escaped[i] = escape_regex_literal(match.classes[i])
    end
    compiled[class_key] = "^(" .. table.concat(escaped, "|") .. ")$"
  else
    compiled[class_key] = match.class
  end

  local title = match.title
  if type(title) == "string" and title ~= "" then
    if title_mode == "exact" then
      compiled[title_key] = "^" .. escape_regex_literal(title) .. "$"
    else
      compiled[title_key] = title
    end
  end

  return compiled
end

function M.validate_document(doc)
  if not is_object(doc) or type(doc.version) ~= "number" then
    return { file = "invalid-file", rules = {} }
  end

  local version = as_integer(doc.version)
  if version and version > 1 then
    return { file = "unsupported-version", rules = {} }
  end
  if version ~= 1 then
    return { file = "invalid-file", rules = {} }
  end

  if doc.revision ~= nil then
    local rev = as_integer(doc.revision)
    if not rev or rev < 0 or rev > MAX_REVISION then
      return { file = "invalid-revision", rules = {} }
    end
  end

  if not is_array(doc.rules) then
    return { file = "invalid-file", rules = {} }
  end
  if #doc.rules > MAX_RULES then
    return { file = "too-many-rules", rules = {} }
  end

  local seen_ids = {}
  local results = {}
  for i = 1, #doc.rules do
    results[i] = validate_rule(doc.rules[i], seen_ids)
  end

  return { file = "ok", rules = results }
end

return M
