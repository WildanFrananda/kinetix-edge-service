local catalogue = require("tests.mutation.catalogue")

local wanted = arg[1]
local field = arg[2]

for _, mutation in ipairs(catalogue.mutations) do
   if wanted == nil then
      print(mutation.id)
   elseif mutation.id == wanted then
      if field == "unit" then
         print(table.concat(mutation.unit, " "))
      elseif field == "integration" then
         print(table.concat(mutation.integration, " "))
      else
         print(mutation.check)
      end
   end
end
