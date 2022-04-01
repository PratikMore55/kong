
local semaphore = require("ngx.semaphore")
local ws_client = require("resty.websocket.client")
local cjson = require("cjson.safe")
local declarative = require("kong.db.declarative")
local protobuf = require("kong.tools.protobuf")
local wrpc = require("kong.tools.wrpc")
local constants = require("kong.constants")
local utils = require("kong.tools.utils")
local system_constants = require("lua_system_constants")
local bit = require("bit")
local ffi = require("ffi")
local assert = assert
local setmetatable = setmetatable
local type = type
local math = math
local xpcall = xpcall
local ngx = ngx
local ngx_log = ngx.log
local ngx_sleep = ngx.sleep
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local kong = kong
local exiting = ngx.worker.exiting
local io_open = io.open
local inflate_gzip = utils.inflate_gzip
local deflate_gzip = utils.deflate_gzip


local KONG_VERSION = kong.version
local CONFIG_CACHE = ngx.config.prefix() .. "/config.cache.json.gz"
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG
local ngx_INFO = ngx.INFO
local PING_INTERVAL = constants.CLUSTERING_PING_INTERVAL
local _log_prefix = "[wrpc-clustering] "
local DECLARATIVE_EMPTY_CONFIG_HASH = constants.DECLARATIVE_EMPTY_CONFIG_HASH

local _M = {
  DPCP_CHANNEL_NAME = "DP-CP_config",
}

function _M.new(parent)
  local self = {
    declarative_config = declarative.new_config(parent.conf),
  }

  return setmetatable(self, {
    __index = function(_, key)
      return _M[key] or parent[key]
    end,
  })
end


function _M:encode_config(config)
  return deflate_gzip(config)
end


function _M:decode_config(config)
  return inflate_gzip(config)
end


function _M:update_config(config_table, config_hash, update_cache)
  assert(type(config_table) == "table")

  if not config_hash then
    config_hash = self:calculate_config_hash(config_table)
  end

  local entities, err, _, meta, new_hash =
              self.declarative_config:parse_table(config_table, config_hash)
  if not entities then
    return nil, "bad config received from control plane " .. err
  end

  if declarative.get_current_hash() == new_hash then
    ngx_log(ngx_DEBUG, _log_prefix, "same config received from control plane, ",
                                    "no need to reload")
    return true
  end

  -- NOTE: no worker mutex needed as this code can only be
  -- executed by worker 0
  local res
  res, err = declarative.load_into_cache_with_events(entities, meta, new_hash)
  if not res then
    return nil, err
  end

  if update_cache then
    -- local persistence only after load finishes without error
    local f
    f, err = io_open(CONFIG_CACHE, "w")
    if not f then
      ngx_log(ngx_ERR, _log_prefix, "unable to open config cache file: ", err)

    else
      local config = assert(cjson_encode(config_table))
      config = assert(self:encode_config(config))
      res, err = f:write(config)
      if not res then
        ngx_log(ngx_ERR, _log_prefix, "unable to write config cache file: ", err)
      end

      f:close()
    end
  end

  return true
end


function _M:init_worker()
  -- ROLE = "data_plane"

  if ngx.worker.id() == 0 then
    local f = io_open(CONFIG_CACHE, "r")
    if f then
      local config, err = f:read("*a")
      if not config then
        ngx_log(ngx_ERR, _log_prefix, "unable to read cached config file: ", err)
      end

      f:close()

      if config and #config > 0 then
        ngx_log(ngx_INFO, _log_prefix, "found cached config, loading...")
        config, err = self:decode_config(config)
        if config then
          config, err = cjson_decode(config)
          if config then
            local res
            res, err = self:update_config(config)
            if not res then
              ngx_log(ngx_ERR, _log_prefix, "unable to update running config from cache: ", err)
            end

          else
            ngx_log(ngx_ERR, _log_prefix, "unable to json decode cached config: ", err, ", ignoring")
          end

        else
          ngx_log(ngx_ERR, _log_prefix, "unable to decode cached config: ", err, ", ignoring")
        end
      end

    else
      -- CONFIG_CACHE does not exist, pre create one with 0600 permission
      local flags = bit.bor(system_constants.O_RDONLY(),
                            system_constants.O_CREAT())

      local mode = ffi.new("int", bit.bor(system_constants.S_IRUSR(),
                                          system_constants.S_IWUSR()))

      local fd = ffi.C.open(CONFIG_CACHE, flags, mode)
      if fd == -1 then
        ngx_log(ngx_ERR, _log_prefix, "unable to pre-create cached config file: ",
                ffi.string(ffi.C.strerror(ffi.errno())))

      else
        ffi.C.close(fd)
      end
    end

    assert(ngx.timer.at(0, function(premature)
      self:communicate(premature)
    end))
  end
end


local wrpc_config_service
local function get_config_service()
  if not wrpc_config_service then
    wrpc_config_service = wrpc.new_service()
    wrpc_config_service:add("kong.services.config.v1.config")
    wrpc_config_service:set_handler("ConfigService.SyncConfig", function(peer, data)
      if peer.config_semaphore then
        if data.config.plugins then
          for _, plugin in ipairs(data.config.plugins) do
            plugin.config = protobuf.pbunwrap_struct(plugin.config)
          end
        end
        data.config._format_version = data.config.format_version
        data.config.format_version = nil

        peer.config_obj.next_config = data.config
        peer.config_obj.next_hash = data.hash
        peer.config_obj.next_config_version = tonumber(data.version)
        if peer.config_semaphore:count() <= 0 then
          -- the following line always executes immediately after the `if` check
          -- because `:count` will never yield, end result is that the semaphore
          -- count is guaranteed to not exceed 1
          peer.config_semaphore:post()
        end
      end
      return { accepted = true }
    end)
  end

  return wrpc_config_service
end

function _M:communicate(premature)

  if premature then
    -- worker wants to exit
    return
  end

  local conf = self.conf

  -- TODO: pick one random CP
  local address = conf.cluster_control_plane
  local log_suffix = " [" .. address .. "]"

  local c = assert(ws_client:new({
    timeout = constants.CLUSTERING_TIMEOUT,
    max_payload_len = conf.cluster_max_payload,
  }))
  local uri = "wss://" .. address .. "/v1/wrpc?node_id=" ..
              kong.node.get_id() ..
              "&node_hostname=" .. kong.node.get_hostname() ..
              "&node_version=" .. KONG_VERSION

  local opts = {
    ssl_verify = true,
    client_cert = self.cert,
    client_priv_key = self.cert_key,
    protocols = "wrpc.konghq.com",
  }
  if conf.cluster_mtls == "shared" then
    opts.server_name = "kong_clustering"
  else
    -- server_name will be set to the host if it is not explicitly defined here
    if conf.cluster_server_name ~= "" then
      opts.server_name = conf.cluster_server_name
    end
  end

  local reconnection_delay = math.random(5, 10)
  do
    local res, err = c:connect(uri, opts)
    if not res then
      ngx_log(ngx_ERR, _log_prefix, "connection to control plane ", uri, " broken: ", err,
        " (retrying after ", reconnection_delay, " seconds)", log_suffix)

      assert(ngx.timer.at(reconnection_delay, function(premature)
        self:communicate(premature)
      end))
      return
    end
  end

  local config_semaphore = semaphore.new(0)
  local peer = wrpc.new_peer(c, get_config_service(), { channel = self.DPCP_CHANNEL_NAME })

  peer.config_semaphore = config_semaphore
  peer.config_obj = self
  peer:spawn_threads()

  do
    local resp, err = peer:call_wait("ConfigService.ReportMetadata", { plugins = self.plugins_list })
    if type(resp) == "table" then
      err = err or resp.error
      resp = resp[1] or resp.ok
    end
    if type(resp) == "table" then
      resp = resp.ok or resp
    end

    if not resp then
      ngx_log(ngx_ERR, _log_prefix, "Couldn't report basic info to CP: ", err)
      assert(ngx.timer.at(reconnection_delay, function(premature)
        self:communicate(premature)
      end))
    end
  end

  -- Here we spawn two threads:
  --
  -- * config_thread: it grabs a received declarative config and apply it
  --                  locally. In addition, this thread also persists the
  --                  config onto the local file system
  -- * ping_thread: performs a ConfigService.PingCP call periodically.

  local config_exit
  local last_config_version = -1

  local config_thread = ngx.thread.spawn(function()
    while not exiting() and not config_exit do
      local ok, err = config_semaphore:wait(1)
      if ok then
        if peer.semaphore == config_semaphore then
          peer.semaphore = nil
          config_semaphore = nil
        end
        local config_table = self.next_config
        local config_hash  = self.next_hash
        if config_table and self.next_config_version > last_config_version then
          ngx_log(ngx_INFO, _log_prefix, "received config #", self.next_config_version, log_suffix)

          local pok, res
          pok, res, err = xpcall(self.update_config, debug.traceback, self, config_table, config_hash, true)
          if pok then
            last_config_version = self.next_config_version
            if not res then
              ngx_log(ngx_ERR, _log_prefix, "unable to update running config: ", err)
            end

          else
            ngx_log(ngx_ERR, _log_prefix, "unable to update running config: ", res)
          end

          if self.next_config == config_table then
            self.next_config = nil
            self.next_hash = nil
          end
        end

      elseif err ~= "timeout" then
        ngx_log(ngx_ERR, _log_prefix, "semaphore wait error: ", err)
      end
    end
  end)

  local ping_thread = ngx.thread.spawn(function()
    while not exiting() do
      local hash = declarative.get_current_hash()

      if hash == true then
        hash = DECLARATIVE_EMPTY_CONFIG_HASH
      end
      assert(peer:call("ConfigService.PingCP", { hash = hash }))
      ngx_log(ngx_INFO, _log_prefix, "sent ping", log_suffix)

      for _ = 1, PING_INTERVAL do
        ngx_sleep(1)
        if exiting() or peer.closing then
          return
        end
      end
    end
  end)

  local ok, err, perr = ngx.thread.wait(ping_thread, config_thread)

  ngx.thread.kill(ping_thread)
  c:close()

  if not ok then
    ngx_log(ngx_ERR, _log_prefix, err, log_suffix)

  elseif perr then
    ngx_log(ngx_ERR, _log_prefix, perr, log_suffix)
  end

  -- the config thread might be holding a lock if it's in the middle of an
  -- update, so we need to give it a chance to terminate gracefully
  config_exit = true
  ok, err, perr = ngx.thread.wait(config_thread)

  if not ok then
    ngx_log(ngx_ERR, _log_prefix, err, log_suffix)

  elseif perr then
    ngx_log(ngx_ERR, _log_prefix, perr, log_suffix)
  end

  if not exiting() then
    assert(ngx.timer.at(reconnection_delay, function(premature)
      self:communicate(premature)
    end))
  end
end

return _M