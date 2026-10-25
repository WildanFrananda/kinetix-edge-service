local record Ngx
   type HeaderValue = string | {string}

   record SharedDict
      get: function(SharedDict, string): number, integer
      set: function(SharedDict, string, number): boolean, string
      safe_add: function(SharedDict, string, number): boolean, string
      incr: function(SharedDict, string, number, number): number, string
      get_keys: function(SharedDict, integer): {string}
   end

   record Thread
   end

   record req
      get_headers: function(integer, boolean): {string: HeaderValue}, string
      get_method: function(): string
      read_body: function()
      get_body_data: function(): string
      get_body_file: function(): string
      start_time: function(): number
   end

   record thread
      spawn: function(function(): string): Thread
      wait: function(Thread): boolean, string
   end

   record re
      find: function(string, string, string): integer, integer, string
      match: function(string, string, string): {string}, string
      gsub: function(string, string, string, string): string, integer, string
   end

   record worker
      id: function(): integer
      pid: function(): integer
   end

   var: {string: string}
   header: {string: HeaderValue}
   shared: {string: SharedDict}
   status: integer
   headers_sent: boolean
   null: userdata
   ERR: integer
   WARN: integer
   INFO: integer

   now: function(): number
   time: function(): integer
   update_time: function()
   sleep: function(number)
   log: function(integer, ...: string)
   print: function(...: string): integer, string
   say: function(...: string): integer, string
   exit: function(integer)
   escape_uri: function(string): string
   encode_base64: function(string, boolean): string
end

return Ngx
