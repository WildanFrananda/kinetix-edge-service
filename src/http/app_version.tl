local app_versions = require("config.app_versions")
local type VersionCheckResult = require("types.version_check_result")

local record app_version
end

local MAX_COMPONENT = 999999

local function trimmed(value: string): string
   return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function parse_segment(raw: string): integer
   if #raw == 0 or #raw > 6 then
      return nil
   end

   if #raw > 1 and string.sub(raw, 1, 1) == "0" then
      return nil
   end

   local numeric = tonumber(raw)
   if numeric == nil or numeric < 0 or numeric > MAX_COMPONENT then
      return nil
   end

   return math.floor(numeric)
end

function app_version.parse_semver(raw: string): integer, integer, integer
   if raw == nil then
      return nil, nil, nil
   end

   local text = trimmed(raw)
   local a, b, c = string.match(text, "^(%d+)%.(%d+)%.(%d+)$")
   if a == nil then
      return nil, nil, nil
   end

   local major = parse_segment(a)
   local minor = parse_segment(b)
   local patch = parse_segment(c)
   if major == nil or minor == nil or patch == nil then
      return nil, nil, nil
   end

   return major, minor, patch
end

function app_version.compare(left: string, right: string): integer
   local la, lb, lc = app_version.parse_semver(left)
   local ra, rb, rc = app_version.parse_semver(right)
   if la == nil or ra == nil then
      return nil
   end

   if la ~= ra then
      return la < ra and -1 or 1
   end

   if lb ~= rb then
      return lb < rb and -1 or 1
   end

   if lc ~= rc then
      return lc < rc and -1 or 1
   end

   return 0
end

function app_version.evaluate(client_header: string, version_header: string): VersionCheckResult
   if version_header == nil then
      return { ok = true, reason = "absent" }
   end

   local clean_version = trimmed(version_header)
   if clean_version == "" then
      return { ok = true, reason = "absent" }
   end

   local major = app_version.parse_semver(clean_version)
   if major == nil then
      return {
         ok = false,
         reason = "malformed_version",
         error_code = "INVALID_REQUEST",
      }
   end

   local clean_client = client_header ~= nil and string.lower(trimmed(client_header)) or ""
   local rule = app_versions.find(clean_client)
   if rule ~= nil and app_version.compare(clean_version, rule.minimum_version) < 0 then
      return {
         ok = false,
         reason = "upgrade_required",
         error_code = "UPGRADE_REQUIRED",
         client = rule.client,
         version = clean_version,
         minimum_version = rule.minimum_version,
         store_url = rule.store_url,
      }
   end

   return {
      ok = true,
      reason = "allowed",
      client = clean_client,
      version = clean_version,
   }
end

return app_version
