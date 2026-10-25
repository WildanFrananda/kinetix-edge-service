local record check
end

local function fail(label: string, detail: string)
   error(label .. ": " .. detail, 3)
end

function check.equal<T>(actual: T, expected: T, label: string)
   if actual ~= expected then
      fail(label, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
   end
end

function check.differ<T>(actual: T, unexpected: T, label: string)
   if actual == unexpected then
      fail(label, "expected anything but " .. tostring(unexpected))
   end
end

function check.truthy(value: boolean, label: string)
   if not value then
      fail(label, "expected true")
   end
end

function check.falsy(value: boolean, label: string)
   if value then
      fail(label, "expected false")
   end
end

function check.present<T>(value: T, label: string)
   if value == nil then
      fail(label, "expected a value, got nil")
   end
end

function check.absent<T>(value: T, label: string)
   if value ~= nil then
      fail(label, "expected nil, got " .. tostring(value))
   end
end

function check.contains(haystack: string, needle: string, label: string)
   if haystack == nil or string.find(haystack, needle, 1, true) == nil then
      fail(label, "expected '" .. tostring(haystack) .. "' to contain '" .. needle .. "'")
   end
end

function check.excludes(haystack: string, needle: string, label: string)
   if haystack ~= nil and string.find(haystack, needle, 1, true) ~= nil then
      fail(label, "expected '" .. haystack .. "' not to contain '" .. needle .. "'")
   end
end

function check.matches(value: string, pattern: string, label: string)
   if value == nil or string.match(value, pattern) == nil then
      fail(label, "expected '" .. tostring(value) .. "' to match " .. pattern)
   end
end

function check.at_most(value: number, limit: number, label: string)
   if value == nil or value > limit then
      fail(label, "expected at most " .. tostring(limit) .. ", got " .. tostring(value))
   end
end

function check.at_least(value: number, limit: number, label: string)
   if value == nil or value < limit then
      fail(label, "expected at least " .. tostring(limit) .. ", got " .. tostring(value))
   end
end

return check
