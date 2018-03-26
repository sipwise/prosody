-- Prosody IM
-- Copyright (C) 2014-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();
local ut = require "util.table";
local jid = require "util.jid";
local array = require "util.array";
local redis = require 'redis';
local redis_config = {
	port = 6739, host = "127.0.0.1",
	server_id = "0", redis_db = "2"
};
local redis_client;

local redis_sessions = module:shared("redis_sessions");

local function test_connection()
	if not redis_client then return nil end;
	local ok, _ = pcall(redis_client.ping, redis_client);
	if not ok then
		redis_client = nil;
	end
end

local function client_connect()
	redis_client = redis.connect(redis_config.host, redis_config.port);
	--module:log("debug", "connected to redis server %s:%d",
	--redis_config.host, redis_config.port);
	if redis_config.redis_db then
		redis_client:select(redis_config.redis_db);
	end
end

local function resource_bind(event)
	local session = event.session;
	local node, domain, resource = jid.split(session.full_jid);
	local full_jid, bare_jid = session.full_jid, node.."@"..domain;

	module:log("debug", "resource-bind from %s", session.host);
	module:log("debug", "save [%s]=%s", full_jid, redis_config.server_id);
	if not test_connection() then client_connect() end
	redis_client:set(full_jid, redis_config.server_id);
	module:log("debug", "append [%s]=>%s:%s", bare_jid, redis_config.server_id, resource);
	redis_client:sadd(bare_jid, redis_config.server_id..":"..resource);
end

local function resource_unbind(event)
	local session, _ = event.session, event.error;
	local node, domain, resource = jid.split(session.full_jid);
	local full_jid, bare_jid = session.full_jid, node.."@"..domain;

	module:log("debug", "resource-unbind from %s", session.host);
	module:log("debug", "remove [%s]=%s", full_jid, redis_config.server_id);
	if not test_connection() then client_connect() end
	redis_client:del(full_jid);
	module:log("debug", "remove [%s]=>%s:%s", bare_jid, redis_config.server_id, resource);
	redis_client:srem(bare_jid, redis_config.server_id..":"..resource);
end

local function split_key(key)
	local t = ut.string.explode(':', key);
	return t[1], t[2];
end

function redis_sessions.get_hosts(j)
	local node, domain = jid.split(j);
	local bare_jid = node.."@"..domain;
	local res = {};
	local l, h, r;

	module:log("debug", "search session:%s host", bare_jid);
	if not test_connection() then client_connect() end
	l = redis_client:smembers(bare_jid);
	--module:log("debug", "l:%s", ut.table.tostring(l));
	for _,v in pairs(l) do
		h, r = split_key(v);
		--module:log("debug", "h:%s r:%s", tostring(h), tostring(r));
		if not res[h] then res[h] = array() end
		res[h]:push(r);
	end
	return res;
end

function redis_sessions.clean_host(j, server_id)
	local bare_jid = jid.bare(j);
	module:log("debug", "clean jid %s from %s", bare_jid, server_id);
	if not test_connection() then client_connect() end
	local l = redis_client:smembers(bare_jid);
	for _,v in pairs(l) do
		local h, _ = split_key(v);
		if h == server_id then
			redis_client:srem(bare_jid, v);
			redis_client:del(v);
			module:log("debug", "removed %s from %s", v, bare_jid);
		end
	end
end

function module.load()
	redis_config = module:get_option("redis_sessions_auth", redis_config);
end

function module.add_host(module)
	module:hook("resource-bind", resource_bind, 200);
	module:hook("resource-unbind", resource_unbind, 200);
	module:log("debug", "hooked at %s", module:get_host());
end
