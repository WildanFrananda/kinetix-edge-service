local record redis
   type Reply = string | integer | userdata
   type Replies = {Reply}

   record ConnectOptions
      pool: string
      pool_size: integer
      backlog: integer
   end

   record Client
      set_timeouts: function(Client, integer, integer, integer)
      connect: function(Client, string, integer, ConnectOptions): integer, string
      get_reused_times: function(Client): integer, string
      set_keepalive: function(Client, integer, integer): integer, string
      close: function(Client): integer, string
      auth: function(Client, string, string): Reply, string
      ping: function(Client): Reply, string
      get: function(Client, string): Reply, string
      set: function(Client, string, string, ...: string): Reply, string
      del: function(Client, ...: string): Reply, string
      hset: function(Client, string, ...: string): Reply, string
      hgetall: function(Client, string): {string}, string
      pexpire: function(Client, string, integer): Reply, string
      pttl: function(Client, string): Reply, string
      multi: function(Client): Reply, string
      exec: function(Client): Replies, string
      keys: function(Client, string): {string}, string
      flushall: function(Client): Reply, string
      acl: function(Client, ...: string): Reply, string
   end

   new: function(): Client, string
end

return redis
