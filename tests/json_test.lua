-- Tests for hypr/json.lua (RFC 8259 decoder and deterministic encoder).

local H = dofile("tests/lua_helpers.lua")
local json = dofile("hypr/json.lua")

local function expect_decode_err(text, opts, label)
  local val, err = json.decode(text, opts)
  H.assert_nil(val, label .. " should fail to decode")
  H.assert_true(type(err) == "string" and #err > 0, label .. " should return an error message")
end

H.test("primitives and whitespace", function()
  local v, err = json.decode(" \t\r\n null \n ")
  H.assert_nil(err)
  H.assert_eq(v, json.null)

  v, err = json.decode("true")
  H.assert_nil(err)
  H.assert_eq(v, true)

  v, err = json.decode("false")
  H.assert_nil(err)
  H.assert_eq(v, false)
end)

H.test("integers stay integers and non-integers become floats", function()
  local v = json.decode("0")
  H.assert_eq(v, 0)
  H.assert_eq(math.type(v), "integer")

  v = json.decode("-42")
  H.assert_eq(v, -42)
  H.assert_eq(math.type(v), "integer")

  v = json.decode("9223372036854775807")
  H.assert_eq(v, math.maxinteger)
  H.assert_eq(math.type(v), "integer")

  v = json.decode("-9223372036854775808")
  H.assert_eq(v, math.mininteger)
  H.assert_eq(math.type(v), "integer")

  v = json.decode("9223372036854775808")
  H.assert_eq(math.type(v), "float")

  v = json.decode("0.5")
  H.assert_eq(v, 0.5)
  H.assert_eq(math.type(v), "float")

  v = json.decode("-1.5e-2")
  H.assert_true(math.abs(v - (-0.015)) < 1e-12)
  H.assert_eq(math.type(v), "float")
end)

H.test("invalid numbers and overflow to inf", function()
  expect_decode_err("01", nil, "leading zero")
  expect_decode_err("-01", nil, "negative leading zero")
  expect_decode_err("+1", nil, "leading plus")
  expect_decode_err(".5", nil, "leading dot")
  expect_decode_err("1.", nil, "trailing dot")
  expect_decode_err("1e", nil, "missing exponent digits")
  expect_decode_err("1e+", nil, "missing exponent digits after sign")
  expect_decode_err("-", nil, "bare minus")
  expect_decode_err("1e309", nil, "positive overflow to inf")
  expect_decode_err("-1e309", nil, "negative overflow to -inf")
  expect_decode_err("1e999999", nil, "huge exponent overflow")
end)

H.test("string escapes and \\u0000", function()
  local v, err = json.decode('"\\"\\\\\\/\\b\\f\\n\\r\\t"')
  H.assert_nil(err)
  H.assert_eq(v, '"\\/\b\f\n\r\t')

  v, err = json.decode('"a\\u0000b"')
  H.assert_nil(err)
  H.assert_eq(#v, 3)
  H.assert_eq(v, "a\0b")

  v, err = json.decode('"\\u0041\\u00e9\\u4e2d"')
  H.assert_nil(err)
  H.assert_eq(v, "Aé中")
end)

H.test("valid and invalid surrogate pairs", function()
  local v, err = json.decode('"\\uD83D\\uDE00"')
  H.assert_nil(err)
  H.assert_eq(v, utf8.char(0x1F600))

  expect_decode_err('"\\uD83D"', nil, "lone high surrogate")
  expect_decode_err('"\\uD83Dabc"', nil, "high surrogate followed by text")
  expect_decode_err('"\\uD83D\\u0041"', nil, "high surrogate followed by BMP char")
  expect_decode_err('"\\uDE00"', nil, "lone low surrogate")
end)

H.test("invalid string syntax, control chars and UTF-8", function()
  expect_decode_err('"\\a"', nil, "unknown escape")
  expect_decode_err('"\\u123"', nil, "short unicode escape")
  expect_decode_err('"\\u123g"', nil, "non-hex unicode escape")
  expect_decode_err('"unterminated', nil, "unterminated string")
  expect_decode_err('"line\nbreak"', nil, "unescaped newline")
  expect_decode_err('"\0"', nil, "unescaped NUL")
  expect_decode_err('"\255"', nil, "invalid UTF-8 byte 0xFF")
  expect_decode_err('"\192\175"', nil, "overlong UTF-8")
  expect_decode_err('"\237\160\128"', nil, "raw UTF-8 surrogate")
end)

H.test("arrays, objects and array_mt distinction", function()
  local empty_arr = json.decode("[]")
  local empty_obj = json.decode("{}")
  H.assert_eq(getmetatable(empty_arr), json.array_mt)
  H.assert_nil(getmetatable(empty_obj))
  H.assert_eq(json.encode(empty_arr), "[]")
  H.assert_eq(json.encode(empty_obj), "{}")

  local complex = json.decode('{"b":[1,null,{"x":true}],"a":{}}')
  H.assert_eq(complex.b[1], 1)
  H.assert_eq(complex.b[2], json.null)
  H.assert_eq(complex.b[3].x, true)
  H.assert_eq(getmetatable(complex.b), json.array_mt)
end)

H.test("trailing tokens, commas, BOM, depth and size limits", function()
  expect_decode_err("", nil, "empty input")
  expect_decode_err("   ", nil, "whitespace only")
  expect_decode_err("{} {}", nil, "trailing object")
  expect_decode_err("1 2", nil, "trailing number")
  expect_decode_err("true false", nil, "trailing boolean")
  expect_decode_err("[1,]", nil, "trailing array comma")
  expect_decode_err('{"a":1,}', nil, "trailing object comma")
  expect_decode_err("\239\187\191{}", nil, "UTF-8 BOM")

  local ok64 = string.rep("[", 64) .. string.rep("]", 64)
  local v64, err64 = json.decode(ok64)
  H.assert_nil(err64)
  H.assert_true(type(v64) == "table")

  local bad65 = string.rep("[", 65) .. string.rep("]", 65)
  expect_decode_err(bad65, nil, "default max_depth 64 exceeded")

  local ok3 = json.decode("[[[]]]", { max_depth = 3 })
  H.assert_true(type(ok3) == "table")
  expect_decode_err("[[[[]]]]", { max_depth = 3 }, "custom max_depth 3 exceeded")

  expect_decode_err('"12345678901"', { max_bytes = 10 }, "custom max_bytes exceeded")
  local small, small_err = json.decode('"12345678"', { max_bytes = 10 })
  H.assert_nil(small_err)
  H.assert_eq(small, "12345678")
end)

H.test("deterministic encode, errors and round trip", function()
  H.assert_eq(json.encode({ z = 1, a = 2, m = 3 }), '{"a":2,"m":3,"z":1}')
  H.assert_eq(json.encode({}), "{}")
  H.assert_eq(json.encode(setmetatable({}, json.array_mt)), "[]")
  H.assert_eq(json.encode({ 10, 20, 30 }), "[10,20,30]")
  H.assert_eq(json.encode(json.null), "null")
  H.assert_eq(json.encode("a\0\1\b\f\n\r\t\"\\é"), '"a\\u0000\\u0001\\b\\f\\n\\r\\t\\"\\\\é"')

  local ok_nan = pcall(json.encode, 0 / 0)
  H.assert_false(ok_nan, "NaN should error on encode")
  local ok_inf = pcall(json.encode, math.huge)
  H.assert_false(ok_inf, "inf should error on encode")
  local ok_ninf = pcall(json.encode, -math.huge)
  H.assert_false(ok_ninf, "-inf should error on encode")

  local cycle = {}
  cycle.self = cycle
  local ok_cycle = pcall(json.encode, cycle)
  H.assert_false(ok_cycle, "circular table should error on encode")

  local sample = {
    version = 1,
    name = 'Line1\nLine2\t"quote"\\slash\0end😀',
    emptyArr = setmetatable({}, json.array_mt),
    emptyObj = {},
    flag = true,
    off = false,
    nothing = json.null,
    nums = { -5, 0, 42, 0.25 },
  }
  local encoded = json.encode(sample)
  local decoded, err = json.decode(encoded)
  H.assert_nil(err)
  H.assert_eq(decoded.version, 1)
  H.assert_eq(math.type(decoded.version), "integer")
  H.assert_eq(decoded.name, sample.name)
  H.assert_eq(getmetatable(decoded.emptyArr), json.array_mt)
  H.assert_nil(getmetatable(decoded.emptyObj))
  H.assert_eq(decoded.flag, true)
  H.assert_eq(decoded.off, false)
  H.assert_eq(decoded.nothing, json.null)
  H.assert_eq(decoded.nums[1], -5)
  H.assert_eq(decoded.nums[4], 0.25)
  H.assert_eq(json.encode(decoded), encoded)
end)

H.finish("json_test")
