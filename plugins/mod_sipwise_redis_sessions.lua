-- Prosody IM
-- Copyright (C) 2014 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local redis = require 'redis';
local redis_config = {
	port = 6739, host = "127.0.0.1",
	server_id = "0", redis_db = "2"
};
local redis_client;

local function test_connection()
	if not redis_client then return nil end;
	local ok, err = pcall(redis_client.ping, redis_client);
	if not ok then
		redis_client = nil;
	end
end

local function client_connect()
	redis_client = redis.connect(redis_config.host, redis_config.port);
	module:log("debug", "connected to redis server %s:%d",
	redis_config.host, redis_config.port);
	if redis_config.redis_db then
		redis_client:select(redis_config.redis_db);
	end
end

local function resource_bind(event)
	local session = event.session;
	module:log("debug", "resource-bind from %s", session.host);
	module:log("debug", "save %s", session.full_jid);
	if not test_connection() then client_connect() end
	redis_client:set(session.full_jid, redis_config.server_id);
end

local function resource_unbind(event)
	local session, err = event.session, event.error;
	module:log("debug", "resource-unbind from %s", session.host);
	module:log("debug", "remove %s", session.full_jid);
	if not test_connection() then client_connect() end
	redis_client:del(session.full_jid);
end

function module.load()
	module:log("debug", "load");
	redis_config = module:get_option("redis_sessions_auth", redis_config);
	redis_enable = client_connect();
end

function module.add_host(module)
	module:hook("resource-bind", resource_bind, 200);
	module:hook("resource-unbind", resource_unbind, 200);
end
