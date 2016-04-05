--
-- Copyright (C) 2014-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("sipwise_vcard_cusax");
module:depends("sipwise_pushd_blocking");

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
local st = require "util.stanza";

local pushd_blocking = module:shared("sipwise_pushd_blocking/pushd_blocking");

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

local function get_members(muc_room)
	local res = set.new();
	if muc_room and muc_room._affiliations then
		for o_jid, _ in pairs(muc_room._affiliations) do
			res:add(o_jid);
		end
	end
	return res;
end

local function get_occupants(muc_room)
	local res = set.new();
	for _, occupant in pairs(muc_room._occupants) do
		res:add(jid_bare(occupant.jid));
	end
	return res;
end

local function get_nick(muc_room, occ_jid)
	if not occ_jid then return nil end

	for nick, occupant in pairs(muc_room._occupants) do
		if occupant.jid == occ_jid then
			return nick;
		end
	end
end

local function get_jid_from_nick(muc_room, occ_nick)
	if not occ_nick then return nil end

	for nick, occupant in pairs(muc_room._occupants) do
		if  occ_nick == nick then
			return occupant.jid;
		end
	end
end

local function get_muc_caller(room_jid)
	local _, host, _ = jid_split(room_jid);
	local room = hosts[host].muc.rooms[jid_bare(room_jid)];
	if not room then
		module:log("warn", "WTF!! %s not here?", jid_bare(room_jid));
		local rooms = set.new();
		for r in pairs(hosts[host].muc.rooms) do
			rooms:add(r);
		end
		module:log("debug", "local rooms: %s", tostring(rooms));
		return nil;
	end
	return get_jid_from_nick(room, room_jid);
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
	local from = stanza.attr.from;
	local muc_stanza = stanza:get_child('x', 'jabber:x:conference');
	local muc = {};
	local room;

	if muc_stanza then
		muc['jid'] = muc_stanza.attr.jid;
	else
		muc['jid'] = jid_bare(from);
	end
	muc['name'], muc['domain'] = jid_split(muc['jid']);
	module:log("debug", "muc:%s", ut.table.tostring(muc));
	local room_host = hosts[muc['domain']].muc;
	if not room_host then
		module:log("debug", "not from MUC host[%s]", muc.domain);
		return nil;
	end
	room = room_host.rooms[muc['jid']];
	if room then
		muc['room'] = room:get_description() or 'Prosody chatroom';
		if muc_stanza then
			muc['invite'] = format("Group chat invitation to '%s' from %s",
				muc['room'], caller_info.display_name);
		end
		return muc;
	end
end

local function is_pushd_blocked(from, to)
	local node, host = jid_split(to);
	local blocked_list = pushd_blocking.get_blocked_jids(node, host);

	module:log("debug", "pushd_blockedlist: %s for [%s]", ut.table.tostring(blocked_list), to);

	local node, host, resource = jid_split(from);
	if ut.table.contains(blocked_list, from)
	   or ut.table.contains(blocked_list, jid_bare(from))
	   or ut.table.contains(blocked_list, host) then
		return true;
	end
	if resource and ut.table.contains(blocked_list, host.."/"..resource) then
		return true;
	end
	return false;
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
			if msg.data_type == 'invite' then
				msg.data_message = muc['invite'];
			end
		end
		msg.data_sender_number = tostring(caller_info.aliases[1]);
		msg.data_sender_name = tostring(caller_info.display_name);
		return msg;
	end
	local function build_push_apns_query(msg, muc)
		if msg.data_type ~= 'invite' then
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
		local muc;
		local caller_jid;
		if stanza.attr.type == 'groupchat' then
			msg.data_type = 'groupchat'
			caller_jid = get_muc_caller(stanza.attr.from);
			module:log("debug", "from:%s -> caller_jid:%s",
				tostring(stanza.attr.from), tostring(caller_jid));
			caller_info = get_caller_info(caller_jid, caller_defaults) or
				caller_defaults;
			muc = get_muc_info(stanza, caller_info);
		else
			msg.data_type = 'message';
			local invite = stanza:get_child('x',
				'http://jabber.org/protocol/muc#user');
			caller_jid = format("%s@%s",
				origin.username or caller.username,
				origin.host or caller.host);
			if invite then
				msg.data_type = 'invite';
				caller_jid = jid_bare(invite:get_child('invite').attr.from) or
					caller_jid;
			end
			caller_info = get_caller_info(caller_jid, caller_defaults) or
				caller_defaults;
			muc = get_muc_info(stanza, caller_info);
		end
		msg.data_sender_jid = caller_jid;
		msg.data_sender_sip = jid_bare(caller_jid);
		msg.push_id = uuid.generate();
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
		if from and is_pushd_blocked(from, to) then
			module:log("debug", "skip pushd message from blocked jid [%s]", from);
			return nil;
		end
		message = {
			data_message = get_message(stanza),
			callee = node,
			domain = host,
		};
		if message.data_message then
			module:log("debug", "message OK");
			if push_enable(node, host) then
				message = build_push_query(message);
				module:log("debug", "message: %s", ut.table.tostring(message));
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

local function fire_offline_message(event, muc_room, off_jid)
	local stanza_c = st.clone(event.stanza);
	stanza_c.attr.to = off_jid;
	stanza_c.attr.from = get_nick(muc_room, stanza_c.attr.from);

	module:log("debug", "stanza[%s] stanza_c[%s]",
		tostring(event.stanza), tostring(stanza_c));

	if is_pushd_blocked(stanza_c.attr.from, stanza_c.attr.to) then
		module:log("debug", "skip pushd message from blocked jid [%s]",
			stanza_c.attr.from);
	else
		module:fire_event('message/offline/handle', {
			origin = event.origin,
			stanza = stanza_c,
		});
	end
end

local function handle_muc_offline(event, room_jid)
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
		local muc_members = get_members(muc_room);
		local muc_occ_online = get_occupants(muc_room);
		local muc_occ_offline = set.difference(muc_members,muc_occ_online);
		module:log("debug", "muc_members[%s]", tostring(muc_members));
		module:log("debug", "muc_occ_online[%s]", tostring(muc_occ_online));
		module:log("debug", "muc_occ_offline[%s]", tostring(muc_occ_offline));
		for off_jid in muc_occ_offline do
			module:log("debug", "fire_offline_message[%s]", off_jid);
			fire_offline_message(event, muc_room, off_jid);
		end
	end
end

local function handle_msg(event)
	local stanza = event.stanza;
	local room_jid = stanza.attr.to;

	if stanza.attr.type ~= 'groupchat' then
		module:log("debug",
			"message[%s] not of type groupchat. Nothing to do here",
			tostring(stanza));
		return nil;
	end
	module:log("debug", "handle_msg room_jid[%s]", tostring(room_jid));
	return handle_muc_offline(event, room_jid);
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