-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2013-2014 Sipwise GmbH
--
-- This is a stripped down version of mod_vcard for returning
-- simply a vcard containing some info of
-- the requested user.
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("sipwise_vcard_cusax");
local st = require "util.stanza";
local jid_split = require "util.jid".split;

local email_query = [[
SELECT bc.email, bccc.email FROM billing.voip_subscribers AS vs
  LEFT join billing.contacts AS bc ON vs.contact_id = bc.id
  LEFT join billing.contracts AS bcc ON vs.contract_id = bcc.id
  LEFT join billing.contacts AS bccc ON bcc.contact_id = bccc.id
WHERE vs.username = ?
  AND vs.domain_id = ?;
]]

local account_id_query = [[
SELECT id, domain_id
FROM provisioning.voip_subscribers
WHERE username = ? AND
domain_id = ( SELECT id FROM provisioning.voip_domains where domain = ?);
]]

local display_usr_query = [[
SELECT vp.attribute, vup.value FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
WHERE vp.attribute = 'display_name'
  AND vup.subscriber_id = ?
]];

local aliases_query = [[
SELECT username FROM provisioning.voip_dbaliases
WHERE subscriber_id = ?;
]];

local mod_sql = module:require("sql");
local params = module:get_option("auth_sql", {
	driver = "MySQL",
	database = "provisioning",
	username = "prosody",
	password = "PW_PROSODY",
	host = "localhost"
});
local engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");

module:add_feature("vcard-temp");

local function get_subscriber_info(user, host)
	local info = { user = user, domain = host, aliases = {} };
	local subscriber_id, domain_id;
	local row;
	-- Reconnect to DB if necessary
	if not engine.conn:ping() then
		engine.conn = nil;
		engine:connect();
	end

	for row in engine:select(account_id_query, user, host) do
		subscriber_id = row[1];
		domain_id = row[2];
	end

	module:log("debug",
		string.format("user:%s subscriber_id:%d domain_id:%d",
			user, subscriber_id, domain_id
		)
	);
	for row in engine:select(display_usr_query, subscriber_id) do
		info['display_name'] = row[2];
		module:log("debug", string.format("display_name:[%s]", row[2]));
	end

	for row in engine:select(aliases_query, subscriber_id) do
		table.insert(info['aliases'], row[1]);
		module:log("debug", string.format("aliases:%s", row[1]));
	end

	for row in engine:select(email_query, user, domain_id) do
		local email = row[1] or row[2];
		if email then
			table.insert(info['email'], email);
			module:log("debug", string.format("email:%s", row[1]));
		end
	end
	return info;
end

local function generate_vcard(info)
	local function add(t, name, value)
		local tmp = {
			name = name,
			attr = { xmlns = "vcard-temp" },
			value
		};
		table.insert(t, tmp)
	end
	local vCard = {
		name = "vCard",
		attr = {
			xmlns = "vcard-temp",
			prodid = "-//HandGen//NONSGML vGen v1.0//EN",
			version = "2.0"
		},
		{
			name = "TEL",
			attr = {  xmlns = "vcard-temp" },
		}
	};
	local uri = info["user"] .. '@' .. info["domain"];
	local _,v;

	add(vCard[1], "NUMBER", "sip:" .. uri);
	add(vCard[1], "VIDEO",  "sip:" .. uri);
	for _,v in ipairs(info['aliases']) do
		add(vCard[1], "NUMBER", v);
	end
	if info['display_name'] then
		add(vCard, "FN", info['display_name']);
	end
	return vCard;
end

local function handle_vcard(event)
	module:log("debug", "handle_vcard");
	local session, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	if stanza.attr.type == "get" then
		local user, host;
		if to then
			user, host = jid_split(to);
		else
			user = session.username;
			host = session.host;
		end
		local info = get_subscriber_info(user, host);
		local vCard = generate_vcard(info);
		session.send(st.reply(stanza):add_child(st.deserialize(vCard)));
	else
		module:log("debug", "reject setting vcard");
		session.send(st.error_reply(stanza, "auth", "forbidden"));
	end
	return true;
end

module:hook("iq/bare/vcard-temp:vCard", handle_vcard);
module:hook("iq/host/vcard-temp:vCard", handle_vcard);
