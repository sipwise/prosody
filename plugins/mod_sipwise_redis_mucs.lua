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
local prosody_hosts = prosody.hosts;
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

	if not test_connection() then client_connect() end
	-- TODO: check that there is no other "room.jid" value?
	if redis_client:set(room.jid, redis_config.server_id) then
		module:log("debug", "save [%s]=%s", room.jid, redis_config.server_id);
	end
	if redis_client:sadd(host, redis_config.server_id..":"..node) > 0 then
		module:log("debug", "append [%s]=>%s:%s", host,
			redis_config.server_id, node);
	end
end

local function muc_destroyed(event)
	local room = event.room;
	local node, host, _ = jid.split(room.jid)
	local muc_host = node.."@"..host;
	local muc_host_key = muc_host..":online";

	module:log("debug", "muc-room-destroyed %s", room.jid);

	if not test_connection() then client_connect() end
	if redis_client:del(room.jid) > 0 then
		module:log("debug", "remove [%s]=%s", room.jid, redis_config.server_id);
	end
	if redis_client:srem(host, redis_config.server_id..":"..node) > 0 then
		module:log("debug", "remove [%s]=>%s:%s", host,
			redis_config.server_id, node);
	end
	if redis_client:del(muc_host_key) > 0 then
		module:log("debug", "remove [%s]", muc_host_key);
	end
end

local function get_occupants(muc)
	local res = set.new();
	if muc and muc._occupants then
		for _, o_data in pairs(muc._occupants) do
			res:add(o_data.jid);
		end
	end
	return res;
end

local function test_show_occupants(room_jid)
	local _, host = jid.split(room_jid);
	local muc = prosody_hosts[host].muc;

	if  muc then
		local muc_room = muc.rooms[room_jid];
		if not muc_room then
			module:log("debug", "muc room[%s] not here. Nothing to do",
				room_jid);
			return nil;
		else
			module:log("debug", "muc_room[%s]: %s", room_jid,
				ut.table.tostring(muc_room));
			local muc_occupants = get_occupants(muc_room);
			local muc_occ_online = redis_mucs.get_online_jids(room_jid);
			local muc_occ_offline = set.difference(muc_occupants,muc_occ_online);
			module:log("debug", "muc_occupants[%s]", tostring(muc_occupants));
			module:log("debug", "muc_occ_online[%s]", tostring(muc_occ_online));
			module:log("debug", "muc_occ_offline[%s]", tostring(muc_occ_offline));
		end
	end
end

local function get_item_jid(stanza)
	local xmlns = "http://jabber.org/protocol/muc#user";
	local s = stanza:get_child('x', xmlns);
	if s then
		local i = s:get_child('item');
		if i then
			return i.attr.jid;
		end
	end
end

local function handle_presence(event)
	local stanza = event.stanza;
	local from = stanza.attr.from;
	local to = stanza.attr.to;
	local node, host, _ = jid.split(from);

	if not hosts:contains(host) then
		module:log("debug", "stanza from[%s] not in known MUC hosts[%s]",
			tostring(host), tostring(hosts));
		return nil
	else
		test_show_occupants(from);
	end

	local muc_host = node.."@"..host;
	local muc_host_key = muc_host..":online";

	if not test_connection() then client_connect() end
	if redis_client:get(muc_host) then

		if stanza.attr.type == 'unavailable' then
			local muc_user_jid = get_item_jid(stanza) or to;
			if muc_user_jid then
				if redis_client:srem(muc_host_key, muc_user_jid) > 0 then
					module:log("debug", "removed [%s]=>%s",
						muc_host_key, muc_user_jid);
				end
			end
		elseif stanza.attr.type == 'error' then
			module:log("debug", "stanza is type error. Nothing to do here");
			return nil;
		else
			if redis_client:sadd(muc_host_key, to) > 0 then
				module:log("debug", "append [%s]=>%s", muc_host_key, to);
			end
		end
	end
end

local function resource_unbind(event)
	local session = event.session;
	local muc_user_jid = session.full_jid

	module:log("debug", "resource-unbind %s", muc_user_jid);

	if not test_connection() then client_connect() end
	for muc_host in hosts do
		local rooms = redis_mucs.get_rooms(muc_host);
		for _,room in pairs(rooms) do
			local muc_host_key = room..'@'..muc_host..":online";
			if redis_client:srem(muc_host_key, muc_user_jid) > 0 then
				module:log("debug", "removed [%s]=>%s",
						muc_host_key, muc_user_jid);
			end
		end
	end
end

local function split_key(key)
	local t = ut.string.explode(':', key);
	return t[1], t[2];
end

function redis_mucs.get_online_jids(room_jid)
	if not test_connection() then client_connect() end
	return set.new(redis_client:smembers(room_jid..":online"));
end

function redis_mucs.get_rooms(host)
	local res = {};
	local l, r;

	module:log("debug", "search rooms at host[%s]", tostring(host));
	if not test_connection() then client_connect() end
	l = redis_client:smembers(host);

	for _,v in pairs(l) do
		_, r = split_key(v);
		ut.table.add(res, r);
	end
	module:log("debug", "found [%s]", ut.table.tostring(res));
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
	module:hook("resource-unbind", resource_unbind, 200);
	module:log("debug", "hooked at %s", host);
end
