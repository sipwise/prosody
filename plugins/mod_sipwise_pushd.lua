--
-- Copyright (C) 2014-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("sipwise_vcard_cusax");
module:depends("sipwise_redis_mucs");

local redis_mucs = module:shared("/*/sipwise_redis_mucs/redis_mucs");
local datamanager = require "util.datamanager";
local mod_sql = module:require("sql");
local format = string.format;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local hosts = prosody.hosts;
local http = require "net.http";
local uuid = require "util.uuid";
local ut = require "util.table";
local set = require "util.set";

local pushd_config = {
	url = "https://127.0.0.1:8080/push",
	gcm = true,
	apns = true,
	call_sound = 'incoming_call.caf',
	msg_sound  = 'incoming_message.caf'
};
local sql_config = {
	driver = "MySQL",
	database = "provisioning",
	username = "prosody",
	password = "PW_PROSODY",
	host = "localhost"
};

local push_usr_query = [[
SELECT vp.attribute, vup.value FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_subscribers vs ON vs.id = vup.subscriber_id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vs.domain_id
WHERE vp.attribute = 'mobile_push_enable'
  AND vs.username = ?
  AND vd.domain = ?;
]];

local push_dom_query = [[
SELECT vp.attribute, vup.value FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_dom_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vup.domain_id
WHERE vp.attribute = 'mobile_push_enable'
  AND vd.domain = ?;
]];
local engine;

-- luacheck: ignore request
local function process_response(response, code, request)
	if code >= 200 and code < 299 then
		module:log("debug", "pushd response OK[%s] %s",
			tostring(code), tostring(response));
	else
		module:log("error", "pushd response KO[%s] %s",
			tostring(code), tostring(response));
	end
end

local function push_enable(username, domain)
	-- Reconnect to DB if necessary
	if not engine.conn:ping() then
		engine.conn = nil;
		engine:connect();
	end
	for row in engine:select(push_dom_query, domain) do
		if row[2] == "1" then
			module:log("debug", "domain mobile_push_enable pref set");
			return true;
		end
	end
	for row in engine:select(push_usr_query, username, domain) do
		if row[2] == "1" then
			module:log("debug", "usr mobile_push_enable pref set");
			return true;
		end
	end
	return false;
end

local function get_caller_info(jid, caller_defaults)
	local node, host = jid_split(jid);
	local vcard = module:shared(format("/%s/sipwise_vcard_cusax/vcard", host));
	if vcard then
		local info = vcard.get_subscriber_info(node, host);
		module:log("debug", "caller_info of %s", jid);
		if not info.display_name then
			module:log("debug", "set display_name to %s", node);
			info.display_name = node;
		end
		if not info.aliases then
			info.aliases = caller_defaults.aliases;
		end
		return info;
	end
end

local function get_callee_badge(jid)
	local node, host = jid_split(jid);
	local result = datamanager.list_load(node, host, "offline");
	if result then
		module:log("debug", "%d offline messages for %s", #result, jid);
		return #result
	end
	module:log("debug", "0 offline messages for %s", jid);
	return 0
end

local function get_message(stanza)
	local body = stanza:get_child('body');
	if body then
		return body:get_text();
	end
end

local function get_muc_info(stanza, caller_info)
	local muc_stanza = stanza:get_child('x', 'jabber:x:conference');
	local muc = {};
	if muc_stanza then
		muc['jid'] = muc_stanza.attr.jid;
		muc['name'], muc['domain'] = jid_split(muc['jid']);
		local room = hosts[muc['domain']].modules.muc.rooms[muc['jid']];
		muc['room'] = room:get_description() or 'Prosody chatroom';
		muc['invite'] = format("Group chat invitation to '%s' from %s",
			muc['room'], caller_info.display_name);
		return muc
	end
end

local function handle_offline(event)
	module:log("debug", "handle_offline");
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	local from = stanza.attr.from;
	local node, host;
	local caller = { username = 'unknow', host = 'unknown.local' };
	local caller_defaults = {display_name = '', aliases = {''}};
	local caller_info;
	-- defaults to "application/x-www-form-urlencoded"
	local http_options = {
		method = "POST",
		body = "",
	}
	local message;

	local function build_push_common_query(msg, muc)
		if muc then
			msg.data_room_jid = muc['jid'];
			msg.data_room_description = muc['room'];
			msg.data_message = muc['invite'];
		end
		msg.data_sender_number = tostring(caller_info.aliases[1]);
		msg.data_sender_name = tostring(caller_info.display_name);
		return msg;
	end
	local function build_push_apns_query(msg, muc)
		if not muc then
			msg.apns_alert = string.format("message received from %s\n",
				caller_info.display_name) .. msg.data_message;
		else
			msg.apns_alert = muc['invite'];
		end
		msg.apns_sound = pushd_config.msg_sound or '';
		msg.apns_badge = tostring(get_callee_badge(to));
		return msg;
	end
	local function build_push_query(msg)
		msg.data_type = 'message';
		local invite = stanza:get_child('x',
			'http://jabber.org/protocol/muc#user');
		local caller_jid = format("%s@%s", origin.username or caller.username,
			origin.host or caller.host);
		if invite then
			msg.data_type = 'invite';
			caller_jid = jid_bare(invite:get_child('invite').attr.from) or
				caller_jid;
		end
		caller_info = get_caller_info(caller_jid, caller_defaults) or
			caller_defaults;
		msg.data_sender_jid = caller_jid;
		msg.data_sender_sip = jid_bare(caller_jid);
		msg.push_id = uuid.generate();
		local muc = get_muc_info(stanza, caller_info);
		msg = build_push_common_query(msg, muc);
		if pushd_config.apns then
			msg = build_push_apns_query(msg, muc);
		end
		return msg;
	end

	module:log("debug", "stanza[%s]", tostring(stanza));

	if from then
		caller.username, caller.host = jid_split(from);
	end

	if to then
		node, host = jid_split(to);
		message = {
			data_message = get_message(stanza),
			callee = node,
			domain = host,
		};
		if message.data_message then
			module:log("debug", "message OK");
			if push_enable(node, host) then
				message = build_push_query(message);
				http_options.body = http.formencode(message);
				if http_options.body then
					module:log("debug", "Sending http pushd request: %s data: %s",
						pushd_config.url, http_options.body);
					http.request(pushd_config.url, http_options, process_response);
				end
			else
				module:log("debug", "no mobile_push_enable pref set for %s", to);
			end
		else
			module:log("debug", "no message body");
		end
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

local function handle_muc_offline(room_jid)
	local _, host = jid_split(room_jid);
	local muc = hosts[host].muc;

	if  muc then
		local muc_room = hosts[host].muc.rooms[room_jid];
		if not muc_room then
			module:log("debug", "muc room[%s] not here. Nothing to do",
				room_jid);
			return nil;
		end

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

local function handle_msg(event)
	local stanza = event.stanza;
	local room_jid = stanza.attr.to;

	if stanza.attr.type ~= 'groupchat' then
		module:log("debug",
			"message not of type groupchat. Nothing to do here");
		return nil;
	end
	module:log("debug", "handle_msg room_jid[%s]", tostring(room_jid));
	return handle_muc_offline(room_jid);
end

module:hook("message/bare", handle_msg, 20);
module:hook("message/offline/handle", handle_offline, 20);

function module.load()
	pushd_config = module:get_option("pushd_config", pushd_config);
	sql_config   = module:get_option("auth_sql", sql_config);
	engine = mod_sql:create_engine(sql_config);
	engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");
	module:log("info", "load OK");
end
