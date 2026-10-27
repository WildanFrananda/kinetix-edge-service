local redis_admin = require("tests.support.redis_admin")

local admin = redis_admin.admin()
admin:flushall()
admin:close()

local rule = redis_admin.edge_rule(nil)
redis_admin.set_edge_rule(nil)

local shown: {string} = {}
for index, part in ipairs(rule) do
   if index == 5 then
      table.insert(shown, ">********")
   elseif index > 1 then
      table.insert(shown, part)
   end
end

print("redis acl: user " .. table.concat(shown, " "))
