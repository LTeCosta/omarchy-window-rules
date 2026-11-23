-- Strict RFC 8259 JSON decoder and deterministic encoder (Lua 5.4+).

local M = {}

local DEFAULT_MAX_BYTES = 1048576
local DEFAULT_MAX_DEPTH = 64

local array_mt = { __json_type = "array" }
local null_mt = {
  __json_type = "null",
  __tostring = function()
    return "null"
  end,
}
local null = setmetatable({}, null_mt)

M.array_mt = array_mt
M.null = null

local SIMPLE_ESCAPES = {
  [0x22] = '"',  -- \"
  [0x5C] = "\\", -- \\
  [0x2F] = "/",  -- \/
  [0x62] = "\b", -- \b
  [0x66] = "\f", -- \f
  [0x6E] = "\n", -- \n
  [0x72] = "\r", -- \r
  [0x74] = "\t", -- \t
}

local ENCODE_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function is_ws(byte)
  return byte == 0x20 or byte == 0x09 or byte == 0x0A or byte == 0x0D
end

local function skip_ws(text, pos, len)
  while pos <= len and is_ws(text:byte(pos)) do
    pos = pos + 1
  end
  return pos
end

local function parse_hex4(text, pos, len)
  if pos + 3 > len then
    return nil
  end
  local hex = text:sub(pos, pos + 3)
  if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
    return nil
  end
  return tonumber(hex, 16)
end

local function decode_string(text, pos, len)
  -- pos points at the opening quote.
  pos = pos + 1
  local parts = {}
  local chunk_start = pos

  while pos <= len do
    local b = text:byte(pos)
    if b == 0x22 then -- closing quote
      if pos > chunk_start then
        local chunk = text:sub(chunk_start, pos - 1)
        if not utf8.len(chunk) then
          return nil, pos, "invalid UTF-8 in string"
        end
        parts[#parts + 1] = chunk
      end
      return table.concat(parts), pos + 1, nil
    elseif b == 0x5C then -- backslash escape
      if pos > chunk_start then
        local chunk = text:sub(chunk_start, pos - 1)
        if not utf8.len(chunk) then
          return nil, pos, "invalid UTF-8 in string"
        end
        parts[#parts + 1] = chunk
      end
      pos = pos + 1
      if pos > len then
        return nil, pos, "unterminated escape sequence"
      end
      local esc = text:byte(pos)
      local mapped = SIMPLE_ESCAPES[esc]
      if mapped then
        parts[#parts + 1] = mapped
        pos = pos + 1
      elseif esc == 0x75 then -- \uXXXX
        local code = parse_hex4(text, pos + 1, len)
        if not code then
          return nil, pos, "invalid unicode escape"
        end
        pos = pos + 5
        if code >= 0xD800 and code <= 0xDBFF then
          if pos + 5 > len or text:byte(pos) ~= 0x5C or text:byte(pos + 1) ~= 0x75 then
            return nil, pos, "unpaired high surrogate"
          end
          local low = parse_hex4(text, pos + 2, len)
          if not low or low < 0xDC00 or low > 0xDFFF then
            return nil, pos, "invalid low surrogate"
          end
          pos = pos + 6
          local cp = 0x10000 + ((code - 0xD800) * 1024) + (low - 0xDC00)
          parts[#parts + 1] = utf8.char(cp)
        elseif code >= 0xDC00 and code <= 0xDFFF then
          return nil, pos, "unexpected low surrogate"
        else
          parts[#parts + 1] = utf8.char(code)
        end
      else
        return nil, pos, "invalid escape sequence"
      end
      chunk_start = pos
    elseif b < 0x20 then
      return nil, pos, "unescaped control character in string"
    else
      pos = pos + 1
    end
  end

  return nil, pos, "unterminated string"
end

local function decode_number(text, pos, len)
  local start_pos = pos
  local b = text:byte(pos)

  if b == 0x2D then -- '-'
    pos = pos + 1
    if pos > len then
      return nil, pos, "invalid number"
    end
    b = text:byte(pos)
  end

  if b == 0x30 then -- '0'
    pos = pos + 1
  elseif b >= 0x31 and b <= 0x39 then -- '1'..'9'
    pos = pos + 1
    while pos <= len do
      local d = text:byte(pos)
      if d < 0x30 or d > 0x39 then
        break
      end
      pos = pos + 1
    end
  else
    return nil, pos, "invalid number"
  end

  if pos <= len and text:byte(pos) == 0x2E then -- '.'
    pos = pos + 1
    if pos > len then
      return nil, pos, "invalid number fraction"
    end
    local d = text:byte(pos)
    if d < 0x30 or d > 0x39 then
      return nil, pos, "invalid number fraction"
    end
    pos = pos + 1
    while pos <= len do
      d = text:byte(pos)
      if d < 0x30 or d > 0x39 then
        break
      end
      pos = pos + 1
    end
  end

  if pos <= len then
    local e = text:byte(pos)
    if e == 0x65 or e == 0x45 then -- 'e' or 'E'
      pos = pos + 1
      if pos <= len then
        local s = text:byte(pos)
        if s == 0x2B or s == 0x2D then -- '+' or '-'
          pos = pos + 1
        end
      end
      if pos > len then
        return nil, pos, "invalid number exponent"
      end
      local d = text:byte(pos)
      if d < 0x30 or d > 0x39 then
        return nil, pos, "invalid number exponent"
      end
      pos = pos + 1
      while pos <= len do
        d = text:byte(pos)
        if d < 0x30 or d > 0x39 then
          break
        end
        pos = pos + 1
      end
    end
  end

  local raw = text:sub(start_pos, pos - 1)
  local num = tonumber(raw)
  if not num or num ~= num or num == math.huge or num == -math.huge then
    return nil, start_pos, "number out of range"
  end
  return num, pos, nil
end

local decode_value

local function decode_array(text, pos, len, depth, max_depth)
  depth = depth + 1
  if depth > max_depth then
    return nil, pos, "maximum nesting depth exceeded"
  end

  local arr = setmetatable({}, array_mt)
  pos = skip_ws(text, pos + 1, len)
  if pos > len then
    return nil, pos, "unterminated array"
  end
  if text:byte(pos) == 0x5D then -- ']'
    return arr, pos + 1, nil
  end

  local idx = 0
  while true do
    local val, err
    val, pos, err = decode_value(text, pos, len, depth, max_depth)
    if err then
      return nil, pos, err
    end
    idx = idx + 1
    arr[idx] = val

    pos = skip_ws(text, pos, len)
    if pos > len then
      return nil, pos, "unterminated array"
    end
    local b = text:byte(pos)
    if b == 0x5D then -- ']'
      return arr, pos + 1, nil
    elseif b == 0x2C then -- ','
      pos = skip_ws(text, pos + 1, len)
      if pos > len then
        return nil, pos, "unterminated array"
      end
    else
      return nil, pos, "expected ',' or ']' in array"
    end
  end
end

local function decode_object(text, pos, len, depth, max_depth)
  depth = depth + 1
  if depth > max_depth then
    return nil, pos, "maximum nesting depth exceeded"
  end

  local obj = {}
  pos = skip_ws(text, pos + 1, len)
  if pos > len then
    return nil, pos, "unterminated object"
  end
  if text:byte(pos) == 0x7D then -- '}'
    return obj, pos + 1, nil
  end

  while true do
    if pos > len or text:byte(pos) ~= 0x22 then
      return nil, pos, "expected string key in object"
    end
    local key, val, err
    key, pos, err = decode_string(text, pos, len)
    if err then
      return nil, pos, err
    end

    pos = skip_ws(text, pos, len)
    if pos > len or text:byte(pos) ~= 0x3A then -- ':'
      return nil, pos, "expected ':' after object key"
    end

    pos = skip_ws(text, pos + 1, len)
    val, pos, err = decode_value(text, pos, len, depth, max_depth)
    if err then
      return nil, pos, err
    end
    obj[key] = val

    pos = skip_ws(text, pos, len)
    if pos > len then
      return nil, pos, "unterminated object"
    end
    local b = text:byte(pos)
    if b == 0x7D then -- '}'
      return obj, pos + 1, nil
    elseif b == 0x2C then -- ','
      pos = skip_ws(text, pos + 1, len)
      if pos > len then
        return nil, pos, "unterminated object"
      end
    else
      return nil, pos, "expected ',' or '}' in object"
    end
  end
end

decode_value = function(text, pos, len, depth, max_depth)
  if pos > len then
    return nil, pos, "unexpected end of input"
  end

  local b = text:byte(pos)
  if b == 0x22 then -- '"'
    return decode_string(text, pos, len)
  elseif b == 0x5B then -- '['
    return decode_array(text, pos, len, depth, max_depth)
  elseif b == 0x7B then -- '{'
    return decode_object(text, pos, len, depth, max_depth)
  elseif b == 0x74 then -- 'true'
    if text:sub(pos, pos + 3) == "true" then
      return true, pos + 4, nil
    end
    return nil, pos, "invalid literal"
  elseif b == 0x66 then -- 'false'
    if text:sub(pos, pos + 4) == "false" then
      return false, pos + 5, nil
    end
    return nil, pos, "invalid literal"
  elseif b == 0x6E then -- 'null'
    if text:sub(pos, pos + 3) == "null" then
      return null, pos + 4, nil
    end
    return nil, pos, "invalid literal"
  elseif b == 0x2D or (b >= 0x30 and b <= 0x39) then
    return decode_number(text, pos, len)
  else
    return nil, pos, "unexpected character"
  end
end

function M.decode(text, opts)
  if type(text) ~= "string" then
    return nil, "expected string input"
  end

  local max_bytes = DEFAULT_MAX_BYTES
  local max_depth = DEFAULT_MAX_DEPTH
  if type(opts) == "table" then
    if type(opts.max_bytes) == "number" then
      max_bytes = opts.max_bytes
    end
    if type(opts.max_depth) == "number" then
      max_depth = opts.max_depth
    end
  end

  local len = #text
  if len > max_bytes then
    return nil, "input exceeds maximum byte limit"
  end

  if len >= 3 and text:byte(1) == 0xEF and text:byte(2) == 0xBB and text:byte(3) == 0xBF then
    return nil, "unexpected UTF-8 BOM"
  end

  local pos = skip_ws(text, 1, len)
  if pos > len then
    return nil, "unexpected end of input"
  end

  local val, next_pos, err = decode_value(text, pos, len, 0, max_depth)
  if err then
    return nil, err .. " at byte " .. tostring(next_pos)
  end

  next_pos = skip_ws(text, next_pos, len)
  if next_pos <= len then
    return nil, "unexpected trailing token at byte " .. tostring(next_pos)
  end

  return val, nil
end

local function escape_char(ch)
  local mapped = ENCODE_ESCAPES[ch]
  if mapped then
    return mapped
  end
  return string.format("\\u%04x", ch:byte(1))
end

local function encode_string(str)
  return '"' .. str:gsub('[\000-\031"\\]', escape_char) .. '"'
end

local function is_null_sentinel(value)
  if value == null then
    return true
  end
  if type(value) == "table" then
    local mt = getmetatable(value)
    return mt ~= nil and mt.__json_type == "null"
  end
  return false
end

local function classify_table(tbl)
  local mt = getmetatable(tbl)
  if mt == array_mt or (mt ~= nil and mt.__json_type == "array") then
    return "array", #tbl
  end

  local count = 0
  local max_k = 0
  local all_int = true
  for k in pairs(tbl) do
    count = count + 1
    if math.type(k) == "integer" and k >= 1 then
      if k > max_k then
        max_k = k
      end
    else
      all_int = false
    end
  end

  if count > 0 and all_int and max_k == count then
    return "array", count
  end
  return "object", count
end

local function encode_value(value, seen, out)
  if value == nil or is_null_sentinel(value) then
    out[#out + 1] = "null"
    return
  end

  local t = type(value)
  if t == "boolean" then
    out[#out + 1] = value and "true" or "false"
  elseif t == "number" then
    if math.type(value) == "integer" then
      out[#out + 1] = string.format("%d", value)
    else
      if value ~= value or value == math.huge or value == -math.huge then
        error("cannot encode non-finite number")
      end
      out[#out + 1] = string.format("%.17g", value)
    end
  elseif t == "string" then
    out[#out + 1] = encode_string(value)
  elseif t == "table" then
    if seen[value] then
      error("cannot encode circular table reference")
    end
    seen[value] = true

    local kind, count = classify_table(value)
    if kind == "array" then
      out[#out + 1] = "["
      for i = 1, count do
        if i > 1 then
          out[#out + 1] = ","
        end
        encode_value(value[i], seen, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(value) do
        if type(k) ~= "string" then
          seen[value] = nil
          error("object keys must be strings")
        end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i = 1, #keys do
        if i > 1 then
          out[#out + 1] = ","
        end
        local k = keys[i]
        out[#out + 1] = encode_string(k)
        out[#out + 1] = ":"
        encode_value(value[k], seen, out)
      end
      out[#out + 1] = "}"
    end

    seen[value] = nil
  else
    error("cannot encode value of type " .. t)
  end
end

function M.encode(value)
  local out = {}
  encode_value(value, {}, out)
  return table.concat(out)
end

return M
