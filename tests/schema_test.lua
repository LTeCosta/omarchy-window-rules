-- Conformance and edge-case tests for hypr/schema.lua.

local H = dofile("tests/lua_helpers.lua")
local json = dofile("hypr/json.lua")
local schema = dofile("hypr/schema.lua")

local function read_file(path)
  local f, err = io.open(path, "rb")
  H.assert_true(f ~= nil, "failed to open " .. path .. ": " .. tostring(err))
  local content = f:read("*a")
  f:close()
  return content
end

local function clone_rule(base, override)
  local rule = {}
  for k, v in pairs(base) do
    rule[k] = v
  end
  if override["$unset"] then
    for i = 1, #override["$unset"] do
      rule[override["$unset"][i]] = nil
    end
  end
  for k, v in pairs(override) do
    if k ~= "$unset" then
      rule[k] = v
    end
  end
  return rule
end

local fixture_text = read_file("tests/fixtures/conformance.json")
local fixture, decode_err = json.decode(fixture_text)
H.assert_nil(decode_err, "conformance.json must decode cleanly")

for idx = 1, #fixture.cases do
  local case = fixture.cases[idx]
  H.test("conformance #" .. idx .. ": " .. case.description, function()
    local doc
    if case.document ~= nil then
      doc = case.document
    else
      local rules = setmetatable({}, json.array_mt)
      for i = 1, #case.rules do
        rules[i] = clone_rule(fixture.baseRule, case.rules[i])
      end
      doc = { version = 1, revision = 0, rules = rules }
    end

    local res = schema.validate_document(doc)
    H.assert_eq(res.file, case.expect.file, "file status mismatch")
    H.assert_eq(#res.rules, #case.expect.rules, "rule count mismatch")

    for i = 1, #case.expect.rules do
      H.assert_eq(res.rules[i].status, case.expect.rules[i], "rule[" .. i .. "] status mismatch")
      if case.expect.rules[i] == "ok" then
        H.assert_true(type(res.rules[i].rule) == "table", "valid rule must produce normalized table")
      else
        H.assert_nil(res.rules[i].rule, "invalid rule must produce nil")
      end
      if case.expect.warnings and case.expect.warnings[i] then
        H.assert_deep_eq(res.rules[i].warnings, case.expect.warnings[i], "rule[" .. i .. "] warnings mismatch")
      end
    end
  end)
end

H.assert_true(type(fixture.textCases) == "table" and #fixture.textCases > 0, "conformance.json must define textCases")
for idx = 1, #fixture.textCases do
  local case = fixture.textCases[idx]
  H.test("conformance textCase #" .. idx .. ": " .. case.description, function()
    local doc, err = json.decode(case.text)
    if doc == nil then
      H.assert_eq("invalid-json", case.expect.file, "unexpected decode failure: " .. tostring(err))
      H.assert_eq(0, #case.expect.rules, "decode failure must expect zero rules")
    else
      local res = schema.validate_document(doc)
      H.assert_eq(res.file, case.expect.file, "file status mismatch")
      H.assert_eq(#res.rules, #case.expect.rules, "rule count mismatch")
      for i = 1, #case.expect.rules do
        H.assert_eq(res.rules[i].status, case.expect.rules[i], "rule[" .. i .. "] status mismatch")
      end
    end
  end)
end

H.assert_true(type(fixture.compileCases) == "table" and #fixture.compileCases > 0, "conformance.json must define compileCases")
for idx = 1, #fixture.compileCases do
  local case = fixture.compileCases[idx]
  H.test("conformance compileCase #" .. idx .. ": " .. case.description, function()
    local actual = schema.compile_match(case.match)
    H.assert_true(type(actual) == "table", "compile_match must return a table")

    local expected_count = 0
    for k, expected_val in pairs(case.expect) do
      expected_count = expected_count + 1
      H.assert_eq(type(actual[k]), "string", "compiled key " .. k .. " must be a string")
      H.assert_eq(actual[k], expected_val, "compiled key " .. k .. " mismatch")
    end

    local actual_count = 0
    for k in pairs(actual) do
      actual_count = actual_count + 1
      H.assert_true(case.expect[k] ~= nil, "unexpected extra key in compiled match: " .. tostring(k))
    end
    H.assert_eq(actual_count, expected_count, "compiled key count mismatch")
  end)
end

H.test("schema.limits exports named validation constants", function()
  H.assert_true(type(schema.limits) == "table")
  H.assert_eq(schema.limits.MAX_RULES, 200)
  H.assert_eq(schema.limits.MAX_ID, 48)
  H.assert_eq(schema.limits.MAX_NAME, 80)
  H.assert_eq(schema.limits.MAX_PATTERN, 256)
  H.assert_eq(schema.limits.MAX_CLASSES, 32)
  H.assert_eq(schema.limits.MAX_WORKSPACE_ID, 9999)
  H.assert_eq(schema.limits.MAX_SPECIAL_NAME, 32)
  H.assert_eq(schema.limits.MAX_MONITOR, 128)
  H.assert_eq(schema.limits.MAX_SLOT, 10)
  H.assert_eq(schema.limits.MAX_ARG, 99)
  H.assert_eq(schema.limits.MAX_SIZE, 16384)
  H.assert_eq(schema.limits.MAX_POSITION, 16384)
  H.assert_eq(schema.limits.MIN_OPACITY, 0.05)
end)

H.test("normalized defaults for missing optional fields", function()
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "minimal",
        name = "Minimal",
        match = { class = "^min$" },
      },
    }, json.array_mt),
  }
  local res = schema.validate_document(doc)
  H.assert_eq(res.file, "ok")
  H.assert_eq(res.rules[1].status, "ok")
  local r = res.rules[1].rule
  H.assert_eq(r.enabled, true)
  H.assert_eq(r.match.mode, "regex")
  H.assert_eq(r.match.class, "^min$")
  H.assert_nil(r.match.classes)
  H.assert_eq(r.match.title, "")
  H.assert_eq(r.match.titleMode, "regex")
  H.assert_eq(r.match.initial, false)
  H.assert_deep_eq(r.workspace, { type = "none" })
  H.assert_eq(r.follow, true)
  H.assert_eq(r.layout, "default")
  H.assert_nil(r.size)
  H.assert_deep_eq(r.position, { type = "none" })
  H.assert_nil(r.monitor)
  H.assert_eq(r.fullscreen, false)
  H.assert_eq(r.maximize, false)
  H.assert_eq(r.pin, false)
  H.assert_nil(r.opacity)
  H.assert_eq(r.noInitialFocus, false)
end)

H.test("apps mode normalization fills defaults and copies classes", function()
  local input_classes = setmetatable({ "com.example.App", "other-app" }, json.array_mt)
  local doc = {
    version = 1,
    rules = setmetatable({
      {
        id = "apps-default",
        name = "Apps Default",
        match = { mode = "apps", classes = input_classes },
      },
    }, json.array_mt),
  }
  local res = schema.validate_document(doc)
  H.assert_eq(res.file, "ok")
  H.assert_eq(res.rules[1].status, "ok")
  local m = res.rules[1].rule.match
  H.assert_eq(m.mode, "apps")
  H.assert_nil(m.class)
  H.assert_deep_eq(m.classes, { "com.example.App", "other-app" })
  H.assert_eq(m.title, "")
  H.assert_eq(m.titleMode, "regex")
  H.assert_eq(m.initial, false)

  input_classes[1] = "mutated"
  H.assert_eq(m.classes[1], "com.example.App", "normalized classes must not alias input table")
end)

H.test("match validation check order and null handling", function()
  local function validate_one(rule)
    local doc = {
      version = 1,
      rules = setmetatable({ rule }, json.array_mt),
    }
    return schema.validate_document(doc).rules[1].status
  end

  H.assert_eq(
    validate_one({
      id = "order-1",
      name = "Order 1",
      match = { mode = "glob", title = 5, initial = "yes" },
      workspace = { type = "bogus" },
    }),
    "invalid-class"
  )
  H.assert_eq(
    validate_one({
      id = "order-2",
      name = "Order 2",
      match = { mode = "apps", classes = setmetatable({}, json.array_mt), titleMode = "glob", initial = "yes" },
      workspace = { type = "bogus" },
    }),
    "invalid-class"
  )
  H.assert_eq(
    validate_one({
      id = "order-3",
      name = "Order 3",
      match = { mode = "apps", classes = { "a" }, titleMode = "glob", initial = "yes" },
      workspace = { type = "bogus" },
    }),
    "invalid-title"
  )
  H.assert_eq(
    validate_one({
      id = "order-4",
      name = "Order 4",
      match = { mode = "apps", classes = { "a" }, title = "", titleMode = "glob" },
    }),
    "invalid-title"
  )
  H.assert_eq(
    validate_one({
      id = "order-5",
      name = "Order 5",
      match = { mode = "apps", classes = { "a" }, title = "ok", titleMode = "exact", initial = "yes" },
      workspace = { type = "bogus" },
    }),
    "invalid-flag"
  )
  H.assert_eq(
    validate_one({ id = "null-mode", name = "Null Mode", match = { mode = json.null, class = "^a$" } }),
    "invalid-class"
  )
  H.assert_eq(
    validate_one({ id = "null-classes", name = "Null Classes", match = { mode = "apps", classes = json.null } }),
    "invalid-class"
  )
  H.assert_eq(
    validate_one({ id = "obj-classes", name = "Obj Classes", match = { mode = "apps", classes = { a = "b" } } }),
    "invalid-class"
  )
  H.assert_eq(
    validate_one({ id = "null-tmode", name = "Null TitleMode", match = { class = "^a$", titleMode = json.null } }),
    "invalid-title"
  )
  H.assert_eq(
    validate_one({ id = "null-init", name = "Null Initial", match = { class = "^a$", initial = json.null } }),
    "invalid-flag"
  )
end)

H.test("200 rules allowed, 201 rules rejected with too-many-rules", function()
  local function make_rules(count)
    local rules = setmetatable({}, json.array_mt)
    for i = 1, count do
      rules[i] = {
        id = "r-" .. i,
        name = "Rule " .. i,
        match = { class = "^app" .. i .. "$" },
      }
    end
    return { version = 1, revision = 0, rules = rules }
  end

  local res200 = schema.validate_document(make_rules(200))
  H.assert_eq(res200.file, "ok")
  H.assert_eq(#res200.rules, 200)

  local res201 = schema.validate_document(make_rules(201))
  H.assert_eq(res201.file, "too-many-rules")
  H.assert_eq(#res201.rules, 0)
end)

H.test("RE2 forbidden-construct scan edge cases", function()
  local function check_class(pattern)
    local doc = {
      version = 1,
      rules = setmetatable({
        { id = "re", name = "RE", match = { class = pattern } },
      }, json.array_mt),
    }
    return schema.validate_document(doc).rules[1].status
  end

  H.assert_eq(check_class("^(?P<app>steam)$"), "ok", "RE2 named group allowed")
  H.assert_eq(check_class("[(?=x)\\1]"), "ok", "constructs inside char class allowed")
  H.assert_eq(check_class("[]a]"), "ok", "leading literal ] in char class allowed")
  H.assert_eq(check_class("[^]a]"), "ok", "leading literal ] after ^ in char class allowed")
  H.assert_eq(check_class("[]](?=a)"), "invalid-class", "lookahead after closed char class rejected")
  H.assert_eq(check_class("[^]](?!a)"), "invalid-class", "negative lookahead after closed negated class rejected")
  H.assert_eq(check_class("(?<foo>bar)"), "invalid-class", "JS named group rejected")
  H.assert_eq(check_class("(?<_foo>bar)"), "invalid-class", "JS named group with underscore rejected")
  H.assert_eq(check_class("foo\\k<bar>"), "invalid-class", "named backreference rejected")
end)

H.test("code-point lengths and invalid UTF-8", function()
  local eighty = string.rep("é", 80)
  local eighty_one = string.rep("é", 81)
  local cp256 = string.rep("é", 256)
  local cp257 = string.rep("é", 257)
  local doc = {
    version = 1,
    rules = setmetatable({
      { id = "u80", name = eighty, match = { class = "^a$" } },
      { id = "u81", name = eighty_one, match = { class = "^a$" } },
      { id = "bad", name = "ok\255", match = { class = "^a$" } },
      { id = "app256", name = "App 256", match = { mode = "apps", classes = { cp256 } } },
      { id = "app257", name = "App 257", match = { mode = "apps", classes = { cp257 } } },
      { id = "appbad", name = "App Bad", match = { mode = "apps", classes = { "ok\255" } } },
      { id = "titbad", name = "Title Bad", match = { mode = "apps", classes = { "a" }, title = "ok\255", titleMode = "exact" } },
    }, json.array_mt),
  }
  local res = schema.validate_document(doc)
  H.assert_eq(res.rules[1].status, "ok")
  H.assert_eq(res.rules[2].status, "invalid-name")
  H.assert_eq(res.rules[3].status, "invalid-name")
  H.assert_eq(res.rules[4].status, "ok")
  H.assert_eq(res.rules[5].status, "invalid-class")
  H.assert_eq(res.rules[6].status, "invalid-class")
  H.assert_eq(res.rules[7].status, "invalid-title")
end)

H.test("revision upper bound matches JS MAX_SAFE_INTEGER (2^53 - 1)", function()
  H.assert_eq(schema.limits.MAX_REVISION, 9007199254740991)

  local max_ok = schema.validate_document({
    version = 1,
    revision = 9007199254740991,
    rules = setmetatable({}, json.array_mt),
  })
  H.assert_eq(max_ok.file, "ok")

  local above_max = schema.validate_document({
    version = 1,
    revision = 9007199254740992,
    rules = setmetatable({}, json.array_mt),
  })
  H.assert_eq(above_max.file, "invalid-revision")

  local decoded_ok, err1 = json.decode('{"version":1,"revision":9007199254740991,"rules":[]}')
  H.assert_nil(err1)
  H.assert_eq(schema.validate_document(decoded_ok).file, "ok")

  local decoded_bad, err2 = json.decode('{"version":1,"revision":9007199254740992,"rules":[]}')
  H.assert_nil(err2)
  H.assert_eq(schema.validate_document(decoded_bad).file, "invalid-revision")
end)

H.finish("schema_test")
