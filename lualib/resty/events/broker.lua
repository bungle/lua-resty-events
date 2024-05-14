local cjson = require "cjson.safe"
local codec = require "resty.events.codec"
local lrucache = require "resty.lrucache"
local queue = require "resty.events.queue"
local server = require("resty.events.protocol").server
local is_timeout = server.is_timeout
local is_closed = server.is_closed

local pairs = pairs
local setmetatable = setmetatable

local ngx = ngx
local log = ngx.log
local exit = ngx.exit
local exiting = ngx.worker.exiting
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local spawn = ngx.thread.spawn
local kill = ngx.thread.kill
local wait = ngx.thread.wait

local decode = codec.decode

local cjson_encode = cjson.encode

local MAX_UNIQUE_EVENTS = 1024
local WEAK_KEYS_MT = { __mode = "k", }

local function terminating(self, worker_connection)
    return self._clients[worker_connection] == nil or exiting()
end

local function get_event_data(self, event_data)
    local unique = event_data.spec.unique
    if unique then
        local uniques = self._uniques
        if uniques:get(unique) then
            if not exiting() then
                log(DEBUG, "unique event is duplicate: ", unique)
            end

            return
        end

        uniques:set(unique, 1, self._opts.unique_timeout)
    end
    return event_data.data, unique
end

-- broadcast to all/unique workers
local function broadcast_events(self, event_data)
    local data, unique = get_event_data(self, event_data)
    if not data then
        return
    end

    local n = 0

    -- pairs is "random" enough for unique
    for _, client_queue in pairs(self._clients) do
        local _, err = client_queue:push(data)
        if err then
            log(ERR, "failed to publish event: ", err, ". ",
                     "data is :", cjson_encode(decode(data)))
        else
            n = n + 1

            if unique then
                break
            end
        end
    end

    log(DEBUG, "event published to ", n, " workers")
end

local function read_thread(self, worker_connection)
    while not terminating(self, worker_connection) do
        local data, err = worker_connection:recv_frame()
        if err then
            if not is_timeout(err) then
                return nil, "failed to read event from worker: " .. err
            end

            -- timeout
            goto continue
        end

        if not data then
            if not exiting() then
                log(ERR, "did not receive event from worker")
            end
            goto continue
        end

        local event_data, err = decode(data)
        if not event_data then
            if not exiting() then
                log(ERR, "failed to decode event data: ", err)
            end
            goto continue
        end

        broadcast_events(self, event_data)

        ::continue::
    end -- while not exiting

    return true
end

local function write_thread(self, worker_connection)
    while not terminating(self, worker_connection) do
        local payload, err = self._clients[worker_connection]:pop()
        if not payload then
            if not is_timeout(err) then
                return nil, "semaphore wait error: " .. err
            end

            goto continue
        end

        local _, err = worker_connection:send_frame(payload)
        if err then
            return nil, "failed to send event: " .. err
        end

        ::continue::
    end -- while not exiting

    return true
end

local _M = {
    _VERSION = '0.1.3',
}

local _MT = { __index = _M, }

function _M.new(opts)
    return setmetatable({
        _opts = opts,
        _uniques = nil,
        _clients = nil,
    }, _MT)
end

function _M:init()
    assert(self._opts)

    local _uniques, err = lrucache.new(MAX_UNIQUE_EVENTS)
    if not _uniques then
        return nil, "failed to create the events cache: " .. (err or "unknown")
    end

    self._uniques = _uniques
    self._clients = setmetatable({}, WEAK_KEYS_MT)

    return true
end

function _M:run()
    local worker_connection, err = server.new()
    if not worker_connection then
        log(ERR, "failed to init socket: ", err)
        exit(444)
    end

    self._clients[worker_connection] = queue.new(self._opts.max_queue_len)

    local read_thread_co = spawn(read_thread, self, worker_connection)
    local write_thread_co = spawn(write_thread, self, worker_connection)

    local ok, err, perr = wait(read_thread_co, write_thread_co)

    self._clients[worker_connection] = nil

    if exiting() then
        kill(read_thread_co)
        kill(write_thread_co)
        return
    end

    if not ok and not is_closed(err) then
        log(ERR, "event broker failed: ", err)
        return exit(ngx.ERROR)
    end

    if perr and not is_closed(perr) then
        log(ERR, "event broker failed: ", perr)
        return exit(ngx.ERROR)
    end

    wait(read_thread_co)
    wait(write_thread_co)

    return exit(ngx.OK)
end

return _M
