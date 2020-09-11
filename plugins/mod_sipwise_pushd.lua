--
-- Copyright (C) 2014-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends("sipwise_vcard_cusax");
module:depends("sipwise_pushd_blocking");

local datamanager = require "util.datamanager";
local sql = require "util.sql";
local format = string.format;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local hosts = prosody.hosts;
local http = require "net.http";
local uuid = require "util.uuid";
local ut = require "util.table";
local set = require "util.set";
local st = require "util.stanza";

local sipwise_offline = module:shared("sipwise_offline/sipwise_offline");
local pushd_blocking = module:shared("sipwise_pushd_blocking/pushd_blocking");

local muc_config = {
	force_persistent = true,
	owner_on_join = true,
	exclude = {}
};
local pushd_config = {
	url = "https://127.0.0.1:8080/push",
	gcm = true,
	apns = true,
	call_sound = 'incoming_call.caf',
	msg_sound  = 'incoming_message.caf',
	muc_config = muc_config
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

local push_silent_query = [[
SELECT vp.id FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_subscribers vs ON vs.id = vup.subscriber_id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vs.domain_id
WHERE vp.attribute = 'mobile_push_silent_list'
  AND vs.username = ?
  AND vd.domain = ?
  AND vup.value = ?;
]];

local default_params = module:get_option("sql");
local engine;

-- Reconnect to DB if necessary
local function reconect_check()
	if not engine.conn:ping() then
		engine.conn = nil;
		engine:connect();
	end
end

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

local function push_silent(username, domain, other)
	reconect_check();
	for row in engine:select(push_silent_query, username, domain, other) do
		module:log("debug", "silent push preference mobile_push_silent_list matches");
		return true;
	end
	return false;
end

local function push_enable(username, domain)
	reconect_check();
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

local function is_local_domain(dom)
	return ut.table.contains(ut.table.keys(hosts), dom);
end

local function get_caller_info(jid, caller_defaults)
	if not jid then
		return nil;
	end
	local node, host = jid_split(jid);
	if not is_local_domain(host) then
		module:log("debug", "caller[%s] not local", jid);
		return nil;
	end
	local vcard = module:shared(format("/%s/sipwise_vcard_cusax/vcard", host));
	if vcard and vcard.get_subscriber_info then
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
	local bare_occ_jid = jid_bare(occ_jid)
	for nick, occupant in pairs(muc_room._occupants) do
		if jid_bare(occupant.jid) == bare_occ_jid then
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

local function get_muc_room(room_jid)
	local _, host, _ = jid_split(room_jid);

	if not hosts[host]then
		module:log("warn", "host [%s] not defined", tostring(host));
		return nil
	end
	if not hosts[host].muc then
		module:log("warn", "muc not enabled here [%s]", tostring(host));
		return nil
	end
	if not hosts[host].muc.rooms then
		module:log("warn", "muc with no rooms defined at [%s]??",
			tostring(host));
		return nil
	end
	return hosts[host].muc.rooms[jid_bare(room_jid)];
end

local function get_muc_caller(room_jid)
	local room = get_muc_room(room_jid)
	if not room then
		module:log("warn", "room %s not here", room_jid);
		return nil;
	end
	return get_jid_from_nick(room, room_jid);
end

local function get_callee_badge(jid)
	local node, host = jid_split(jid);
	local result = 0;
	if sipwise_offline.get_num then
		result = sipwise_offline.get_num(node, host);
	else
		local offline = datamanager.list_load(node, host, "offline");
		if offline then
			result = #offline;
		end
	end
	-- plus the one in process
	result = result + 1;
	module:log("debug", "%d offline messages for %s", result, jid);
	return result;
end

local function is_invite(stanza)
	if stanza:get_child('x', 'http://jabber.org/protocol/muc#user') then
		return true
	end
end

local function is_attachment(stanza)
	if stanza:get_child('x', 'jabber:x:oob') then
		return true
	end
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
	if not is_local_domain(muc['domain']) then
		module:log("debug", "not from local host[%s]", tostring(muc.domain));
		return nil;
	end
	local room_host = hosts[muc['domain']].muc;
	if not room_host then
		module:log("debug", "not from MUC host[%s]", muc.domain);
		return nil;
	end
	room = room_host.rooms[muc['jid']];
	if room then
		muc['room'] = room:get_description() or muc['name'];
		if muc_stanza then
			muc['invite'] = format("Group chat invitation to '%s' from %s",
				muc['room'], caller_info.display_name);
		end
		return muc;
	end
end

local function is_pushd_blocked(from, to)
	local node_to, host_to = jid_split(to);
	local blocked_list = pushd_blocking.get_blocked_jids(node_to, host_to);

	module:log("debug", "pushd_blockedlist: %s for [%s]", ut.table.tostring(blocked_list), to);

	local _, host_from, resource_from = jid_split(from);
	if ut.table.contains(blocked_list, from)
	   or ut.table.contains(blocked_list, jid_bare(from))
	   or ut.table.contains(blocked_list, host_from) then
		return true;
	end
	if resource_from and ut.table.contains(blocked_list, host_from.."/"..resource_from) then
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
	local function build_push_apns_query(msg, muc, silent)
		if silent then
			msg['apns_content-available'] = '1';
		else
			if msg.data_type ~= 'invite' then
				msg.apns_alert = string.format("Message from %s:\n",
					caller_info.display_name) .. msg.data_message;
			else
				msg.apns_alert = muc['invite'];
			end
			msg.apns_sound = pushd_config.msg_sound or '';
			msg.apns_badge = tostring(get_callee_badge(to));
		end
		return msg;
	end
	local function build_push_query(msg)
		local muc;
		local caller_jid;
		local silent;
		if stanza.attr.type == 'groupchat' then
			msg.data_type = 'groupchat'
			caller_jid = get_muc_caller(stanza.attr.from);
			module:log("debug", "from:%s -> caller_jid:%s",
				tostring(stanza.attr.from), tostring(caller_jid));
			caller_info = get_caller_info(caller_jid, caller_defaults) or
				caller_defaults;
			muc = get_muc_info(stanza, caller_info);
			silent = push_silent(msg.callee, msg.domain, muc['jid']);
		else
			msg.data_type = 'message';
			caller_jid = format("%s@%s",
				origin.username or caller.username,
				origin.host or caller.host);
			if is_invite(stanza) then
				msg.data_type = 'invite';
				caller_jid = jid_bare(invite:get_child('invite').attr.from) or
					caller_jid;
			elseif is_attachment(stanza) then
				msg.data_message = "new attachment";
			end
			caller_info = get_caller_info(caller_jid, caller_defaults) or
				caller_defaults;
			muc = get_muc_info(stanza, caller_info);
			silent = push_silent(msg.callee, msg.domain, caller_jid);
		end
		if silent then
			msg.data_silent = '1';
		else
			msg.data_silent = '0';
		end
		msg.data_sender_jid = caller_jid;
		msg.data_sender_sip = jid_bare(caller_jid);
		msg.push_id = uuid.generate();
		msg = build_push_common_query(msg, muc);
		if pushd_config.apns then
			msg = build_push_apns_query(msg, muc, silent);
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
			data_full_message = tostring(stanza),
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
	local orig_from = event.stanza.attr.from;
	stanza_c.attr.to = off_jid;
	stanza_c.attr.from = get_nick(muc_room, orig_from);

	module:log("debug", "stanza[%s] stanza_c[%s]",
		tostring(event.stanza), tostring(stanza_c));
	if not stanza_c.attr.from then
		module:log("error", "original from[%s] not found at muc_room",
			tostring(orig_from));
		return nil;
	end
	if is_pushd_blocked(stanza_c.attr.from, stanza_c.attr.to) then
		module:log("debug", "skip pushd message from blocked jid [%s]",
			stanza_c.attr.from);
	elseif is_pushd_blocked(orig_from, stanza_c.attr.to) then
		module:log("debug", "skip pushd message from blocked jid [%s]",
			orig_from);
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
		elseif ut.table.contains(pushd_config.muc_config.exclude, room_jid) then
			module:log("debug", "muc room[%s] excluded from pushd", room_jid);
			return nil;
		end

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
	module:log("debug", "handle_msg");
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

local function handle_muc_created(event)
	local room = event.room;
	if pushd_config.muc_config.force_persistent then
		room:set_persistent(true);
		module:log("debug", "persistent room[%s] forced on creation",
			room:get_name());
	end
end

local function handle_muc_config(event)
	local room, fields = event.room, event.fields;
	local name = fields['muc#roomconfig_roomname'] or room:get_name();
	local persistent = fields['muc#roomconfig_persistentroom'];
	if pushd_config.muc_config.force_persistent and not persistent then
		fields['muc#roomconfig_persistentroom'] = true;
		event.changed = true;
		module:log("debug", "persistent room[%s] forced", name);
	end
end

local function handle_muc_presence(event)
	if not pushd_config.muc_config.owner_on_join then return; end
	local stanza = event.stanza;
	if stanza.attr.type == "unavailable" then return; end

	local room = get_muc_room(stanza.attr.to);
	if not room then return; end
	local from_jid = jid_bare(stanza.attr.from);
	local affiliation = room._affiliations[from_jid];
	if affiliation ~= "owner" then
		room._affiliations[from_jid] = "owner";
		module:log("debug", "[%s] set affiliation to 'owner' for [%s]",
			room:get_name(), from_jid);
	end
end

local function handle_muc_presence_out(event)
	local stanza = event.stanza;
	local muc_stanza = stanza:get_child('x',
		'http://jabber.org/protocol/muc#user');

	if muc_stanza then
		local item = muc_stanza:get_child('item');
		if not item.nick and stanza.attr.from then
			local nick = select(3, jid_split(stanza.attr.from));
			if nick then
				item.attr.nick = nick;
				module:log("debug", "added nick[%s] tag", nick);
			end
		end
	end
end

if module:get_host_type() == "component" then
	module:hook("muc-room-created", handle_muc_created, 20);
	module:hook("muc-config-submitted", handle_muc_config, 20);
	module:hook("presence/full", handle_muc_presence, 501);
else
	module:hook("presence/full", handle_muc_presence_out, 501);
end
module:hook("message/bare", handle_msg, 20);
module:hook("message/offline/handle", handle_offline, 20);

local function normalize_params(params)
	assert(params.driver and params.database,
		"Configuration error: Both the SQL driver and the database need to be specified");
	return params;
end

function module.load()
	if prosody.prosodyctl then return; end
	local engines = module:shared("/*/sql/connections");
	local params = normalize_params(module:get_option("auth_sql", default_params));
	engine = engines[sql.db2uri(params)];
	if not engine then
		module:log("debug", "Creating new engine");
		engine = sql:create_engine(params);
		engines[sql.db2uri(params)] = engine;
	end
	engine:connect();
	pushd_config = module:get_option("pushd_config", pushd_config);
	if not pushd_config.muc_config then
		pushd_config.muc_config = muc_config
	end

	module:log("debug", "load OK");
end
