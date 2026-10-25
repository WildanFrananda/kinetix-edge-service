local catalogue = require("tests.mutation.catalogue")

local wanted = arg[1]
local root = arg[2]

for _, mutation in ipairs(catalogue.mutations) do
   if mutation.id == wanted then
      local path = root .. "/" .. mutation.file
      local source = assert(io.open(path, "r"))
      local text = source:read("*a")
      source:close()

      local first = string.find(text, mutation.old, 1, true)
      if first == nil then
         error(wanted .. ": the code to mutate is not in " .. mutation.file)
      end

      if string.find(text, mutation.old, first + 1, true) ~= nil then
         error(wanted .. ": the code to mutate appears more than once in " .. mutation.file)
      end

      local mutated = string.sub(text, 1, first - 1) .. mutation.new .. string.sub(text, first + #mutation.old)
      local target = assert(io.open(path, "w"))
      target:write(mutated)
      target:close()

      print(mutation.file)
      os.exit(0)
   end
end

error("no mutation " .. tostring(wanted))
