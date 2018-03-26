-- Prosody IM
-- Copyright (C) 2014-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:set_global();
local set = require "util.set";
local ut = require "util.table";
local jid = require "util.jid";
local redis = require 'redis';
local redis_config = {
	port = 6739, host = "127.0.0.1",
	server_id = "0", redis_db = "2"
};
local redis_client;
local redis_mucs = module:shared("redis_mucs");

local function test_connection()
	if not redis_client then return nil end;
	local ok, _ = pcall(redis_client.ping, redis_client);
	if not ok then
		redis_client = nil;
	end
end

local function client_connect()
	redis_client = redis.connect(redis_config.host, redis_config.port);
	if redis_config.redis_db then
		redis_client:select(redis_config.redis_db);
	end
end

local function muc_created(event)
	local room = event.room;

	redis_mucs.set_room_host(room.jid, redis_config.server_id);
	module:log("debug", "muc-room-created %s", room.jid);
end

local function muc_destroyed(event)
	local room = event.room;

	redis_mucs.clean_room_host(room.jid, redis_config.server_id);
	module:log("debug", "muc-room-destroyed %s", room.jid);
end

local function split_key(key)
	local t = ut.string.explode(':', key);
	return t[1], t[2];
end

function redis_mucs.get_rooms(host)
	local res = set.new();
	local l, r;

	module:log("debug", "search rooms at host[%s]", tostring(host));
	if not test_connection() then client_connect() end
	l = redis_client:smembers(host);

	for _,v in pairs(l) do
		_, r = split_key(v);
		res:add(r..'@'..host);
	end
	module:log("debug", "found [%s]", tostring(res));
	return res;
end

function redis_mucs.set_room_host(room_jid, server_id)
	local node, host, _ = jid.split(room_jid);
	local bare_jid = node.."@"..host;

	if not test_connection() then client_connect() end
	-- TODO: check that there is no other "bare_jid" value?
	if redis_client:set(bare_jid, server_id) then
		module:log("debug", "save [%s]=%s", bare_jid, server_id);
	end
	if redis_client:sadd(host, server_id..":"..node) > 0 then
		module:log("debug", "append [%s]=>%s:%s", host,
			server_id, node);
	end
end

function redis_mucs.get_room_host(room_jid)
	local node, domain, _ = jid.split(room_jid);
	local bare_jid = node.."@"..domain;

	module:log("debug", "search room:%s host", bare_jid);
	if not test_connection() then client_connect() end
	return redis_client:get(bare_jid);
end

function redis_mucs.clean_room_host(room_jid, server_id)
	local node, host, _ = jid.split(room_jid);
	local bare_jid = node.."@"..host;

	if not test_connection() then client_connect() end
	if redis_client:del(bare_jid) > 0 then
		module:log("debug", "remove [%s]=%s", bare_jid, server_id);
	end
	if redis_client:srem(host, server_id..":"..node) > 0 then
		module:log("debug", "remove [%s]=>%s:%s", host, server_id, node);
	end
end

function module.load()
	redis_config = module:get_option("redis_sessions_auth", redis_config);
end

function module.add_host(module)
	if module:get_host_type() == "component" then
		module:hook("muc-room-created", muc_created, 200);
		module:hook("muc-room-destroyed", muc_destroyed, 200);
	end
	module:log("debug", "hooked at %s", module:get_host());
end
