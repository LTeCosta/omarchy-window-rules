-- Minimal test harness shared by Lua 5.4+ test suites.

local H = {}

local passed = 0
local failed = 0

local function format_val(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

function H.deep_eq(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not H.deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

function H.assert_true(cond, msg)
  if not cond then
    error(msg or "expected truthy value", 2)
  end
end

function H.assert_false(cond, msg)
  if cond then
    error(msg or "expected falsy value", 2)
  end
end

function H.assert_nil(val, msg)
  if val ~= nil then
    error((msg or "expected nil") .. " (got " .. format_val(val) .. ")", 2)
  end
end

function H.assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assertion failed") .. ": expected " .. format_val(expected) .. ", got " .. format_val(actual), 2)
  end
end

function H.assert_deep_eq(actual, expected, msg)
  if not H.deep_eq(actual, expected) then
    error(msg or "tables are not deeply equal", 2)
  end
end

function H.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL: " .. name .. "\n  " .. tostring(err) .. "\n")
  end
end

function H.finish(suite_name)
  print(string.format("%s: %d passed, %d failed", suite_name, passed, failed))
  if failed > 0 then
    os.exit(1)
  end
end

return H
