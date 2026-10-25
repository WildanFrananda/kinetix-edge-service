local redis_admin = require("tests.support.redis_admin")
local redis_store = require("adapters.redis_store")

local rule: {string} = {
   "SETUSER",
   "edge",
   "reset",
   "on",
   ">" .. redis_admin.edge_password,
   "~edge:*",
   "resetchannels",
   "-@all",
}
for _, command in ipairs(redis_store.commands) do
   table.insert(rule, "+" .. string.lower(command))
end

local admin = redis_admin.admin()
admin:flushall()

local reply, failure = admin:acl(table.unpack(rule))
admin:close()
if reply ~= "OK" then
   error("ACL SETUSER edge was refused: " .. tostring(failure))
end

local shown: {string} = {}
for index, part in ipairs(rule) do
   if index == 5 then
      table.insert(shown, ">********")
   elseif index > 1 then
      table.insert(shown, part)
   end
end

print("redis acl: user " .. table.concat(shown, " "))
