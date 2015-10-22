-- Prosody IM
-- Copyright (C) 2014-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:set_global();

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

local function muc_created(room)
	module:log("debug", "muc-room-created %s", ut.table.tostring(room.jid));
	module:log("debug", "save [%s]=%s", room.jid, redis_config.server_id);
	if not test_connection() then client_connect() end
	redis_client:set(room.jid, redis_config.server_id);
end

local function muc_destroyed(room)
	module:log("debug", "muc-room-destroyed %s", ut.table.tostring(room.jid));
	module:log("debug", "remove [%s]=%s", room.jid, redis_config.server_id);
	if not test_connection() then client_connect() end
	redis_client:del(room.jid);
end

function redis_mucs.get_room_host(room_jid)
	local node, domain = jid.split(room_jid);
	local bare_jid = node.."@"..domain;

	module:log("debug", "search room:%s host", bare_jid);
	if not test_connection() then client_connect() end
	return redis_client:get(bare_jid);
end


function module.load()
	redis_config = module:get_option("redis_sessions_auth", redis_config);
end

function module.add_host(module)
	module:hook("muc-room-created", muc_created, 200);
	module:hook("muc-room-destroyed", muc_destroyed, 200);
	module:log("debug", "hooked at %s", module:get_host());
end
