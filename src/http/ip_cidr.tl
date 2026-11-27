local record ip_cidr
end

local MAX_IPV4_PART = 255
local POW2: {integer: number} = {
   [0] = 1,
   [1] = 2,
   [2] = 4,
   [3] = 8,
   [4] = 16,
   [5] = 32,
   [6] = 64,
   [7] = 128,
   [8] = 256,
   [9] = 512,
   [10] = 1024,
   [11] = 2048,
   [12] = 4096,
   [13] = 8192,
   [14] = 16384,
   [15] = 32768,
   [16] = 65536,
   [17] = 131072,
   [18] = 262144,
   [19] = 524288,
   [20] = 1048576,
   [21] = 2097152,
   [22] = 4194304,
   [23] = 8388608,
   [24] = 16777216,
   [25] = 33554432,
   [26] = 67108864,
   [27] = 134217728,
   [28] = 268435456,
   [29] = 536870912,
   [30] = 1073741824,
   [31] = 2147483648,
   [32] = 4294967296,
}

local function parse_octet(part: string): integer
   if #part == 0 or #part > 3 then
      return nil
   end

   if #part > 1 and string.sub(part, 1, 1) == "0" then
      return nil
   end

   local numeric = tonumber(part)
   if numeric == nil or numeric < 0 or numeric > MAX_IPV4_PART then
      return nil
   end

   return math.floor(numeric)
end

function ip_cidr.parse_ipv4(address: string): number
   if address == nil or address == "" then
      return nil
   end

   local a, b, c, d = string.match(address, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
   if a == nil then
      return nil
   end

   local o1 = parse_octet(a)
   local o2 = parse_octet(b)
   local o3 = parse_octet(c)
   local o4 = parse_octet(d)
   if o1 == nil or o2 == nil or o3 == nil or o4 == nil then
      return nil
   end

   return ((o1 * 256 + o2) * 256 + o3) * 256 + o4
end

local function parse_prefix(raw: string): integer
   if raw == nil then
      return 32
   end

   if #raw == 0 or #raw > 2 or string.match(raw, "^%d+$") == nil then
      return nil
   end

   local prefix = tonumber(raw)
   if prefix == nil or prefix < 0 or prefix > 32 then
      return nil
   end

   return math.floor(prefix)
end

function ip_cidr.matches(address: string, cidr: string): boolean
   local ip_value = ip_cidr.parse_ipv4(address)
   if ip_value == nil or cidr == nil or cidr == "" then
      return false
   end

   local slash = string.find(cidr, "/", 1, true)
   local net_text = slash ~= nil and string.sub(cidr, 1, slash - 1) or cidr
   local prefix_text = slash ~= nil and string.sub(cidr, slash + 1) or nil

   local net_value = ip_cidr.parse_ipv4(net_text)
   local prefix = parse_prefix(prefix_text)
   if net_value == nil or prefix == nil then
      return false
   end

   if prefix == 0 then
      return true
   end

   local divisor = POW2[32 - prefix]
   return math.floor(ip_value / divisor) == math.floor(net_value / divisor)
end

function ip_cidr.matches_any(address: string, cidrs: {string}): boolean
   if address == nil or cidrs == nil then
      return false
   end

   for _, cidr in ipairs(cidrs) do
      if ip_cidr.matches(address, cidr) then
         return true
      end
   end

   return false
end

return ip_cidr
