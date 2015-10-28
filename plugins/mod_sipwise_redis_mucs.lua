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
local hosts;
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
	local node, host, _ = jid.split(room.jid)

	module:log("debug", "muc-room-created %s", room.jid);
	module:log("debug", "save [%s]=%s", room.jid, redis_config.server_id);
	if not test_connection() then client_connect() end
	redis_client:set(room.jid, redis_config.server_id);
	module:log("debug", "append [%s]=>%s:%s", host,
		redis_config.server_id, node);
    redis_client:sadd(host, redis_config.server_id..":"..node);
end

local function muc_destroyed(event)
	local room = event.room;
	local node, host, _ = jid.split(room.jid)

	module:log("debug", "muc-room-destroyed %s", room.jid);
	module:log("debug", "remove [%s]=%s", room.jid, redis_config.server_id);
	if not test_connection() then client_connect() end
	redis_client:del(room.jid);
	module:log("debug", "remove [%s]=>%s:%s", host,
		redis_config.server_id, node);
    redis_client:srem(host, redis_config.server_id..":"..node);
end

local function handle_presence(event)
	local from = event.stanza.attr.from;
	local node, host, _ = jid.split(from);

	if not hosts:contains(host) then
		module:log("debug", "stanza not from[%s] known MUC[%s]",
			tostring(host), tostring(hosts));
		return nil
	end

	module:log("debug", "stanza:%s", tostring(event.stanza));

	if not test_connection() then client_connect() end
	if redis_client:get(node.."@"..host) then
		module:log("debug", "my stanza:%s", tostring(event.stanza));
	end
end

local function split_key(key)
	local t = ut.string.explode(':', key);
	return t[1], t[2];
end

function redis_mucs.get_rooms(host)
	local res = {};
	local l, r;

	module:log("debug", "search rooms at %s host", host);
	if not test_connection() then client_connect() end
	l = redis_client:smembers(host);

	for _,v in pairs(l) do
		_, r = split_key(v);
		ut.table.add(res, r);
	end
	return res;
end

function redis_mucs.get_room_host(room_jid)
	local node, domain = jid.split(room_jid);
	local bare_jid = node.."@"..domain;

	module:log("debug", "search room:%s host", bare_jid);
	if not test_connection() then client_connect() end
	return redis_client:get(bare_jid);
end

function redis_mucs.get_hosts()
	return hosts;
end

function module.load()
	redis_config = module:get_option("redis_sessions_auth", redis_config);
	hosts = set.new();
end

function module.add_host(module)
	local host = module:get_host();
	if module:get_host_type() == "component" then
		module:hook("muc-room-created", muc_created, 200);
		module:hook("muc-room-destroyed", muc_destroyed, 200);
		hosts:add(host);
	end
	module:hook("presence/full", handle_presence, 200);
	module:hook("presence/bare", handle_presence, 200);
	module:log("debug", "hooked at %s", host);
end
