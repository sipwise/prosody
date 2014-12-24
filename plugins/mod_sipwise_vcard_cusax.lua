-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2013-2014 Sipwise GmbH
--
-- This is a stripped down version of mod_vcard for returning
-- simply a vcard containing some info of
-- the requested user.
-- http://xmpp.org/extensions/xep-0054.html
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("sipwise_vcard_cusax");
local st = require "util.stanza";
local jid_split = require "util.jid".split;

local vcard = module:shared("vcard");

local email_query = [[
SELECT bc.email, bccc.email FROM billing.voip_subscribers AS vs
  LEFT join billing.contacts AS bc ON vs.contact_id = bc.id
  LEFT join billing.contracts AS bcc ON vs.contract_id = bcc.id
  LEFT join billing.contacts AS bccc ON bcc.contact_id = bccc.id
  LEFT join billing.domains AS bd ON vs.domain_id = bd.id
WHERE vs.username = ? AND bd.domain = ?;
]]

local display_usr_query = [[
SELECT vp.attribute, vup.value FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_subscribers AS ps ON ps.id = vup.subscriber_id
  LEFT JOIN provisioning.voip_domains AS pd ON ps.domain_id = pd.id
WHERE vp.attribute = 'display_name'
  AND ps.username = ? AND pd.domain = ?
]];

local aliases_query = [[
SELECT pa.username, pa.is_primary FROM provisioning.voip_dbaliases AS pa
  LEFT JOIN provisioning.voip_subscribers AS ps ON ps.id = pa.subscriber_id
  LEFT JOIN provisioning.voip_domains AS pd ON ps.domain_id = pd.id
WHERE ps.username = ? AND pd.domain = ? ORDER BY 2 DESC;
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

function vcard.get_subscriber_info(user, host)
	local info = { user = user, domain = host, aliases = {} };
	local row;
	-- Reconnect to DB if necessary
	if not engine.conn:ping() then
		engine.conn = nil;
		engine:connect();
	end

	for row in engine:select(display_usr_query, user, host) do
		info['display_name'] = row[2];
		module:log("debug", string.format("display_name:[%s]", row[2]));
	end

	for row in engine:select(aliases_query, user, host) do
		table.insert(info['aliases'], row[1]);
		module:log("debug", string.format("aliases:%s", row[1]));
	end

	for row in engine:select(email_query, user, host) do
		local email = row[1] or row[2];
		if email then
			info['email'] = email;
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
		};
		if value then table.insert(tmp, value) end
		if t then
			table.insert(t, tmp);
		else
			return tmp;
		end
	end
	local vCard = {
		name = "vCard",
		attr = {
			xmlns = "vcard-temp",
			prodid = "-//HandGen//NONSGML vGen v1.0//EN",
			version = "2.0"
		}
	};
	local uri = info["user"] .. '@' .. info["domain"];
	local t,_,v;

	t = add(nil, "NUMBER", "sip:" .. uri);
	add(vCard, "TEL", t);
	t = add(nil, "VIDEO",  "sip:" .. uri);
	add(vCard, "TEL", t);
	for _,v in ipairs(info['aliases']) do
		t = add(nil, "NUMBER", v);
		add(vCard, "TEL", t);
	end
	if info['display_name'] then
		add(vCard, "FN", info['display_name']);
	end
	if info['email'] then
		t = add(nil, "USERID", info['email']);
		add(vCard, "EMAIL", t);
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
		local info = vcard.get_subscriber_info(user, host);
		local vCard = generate_vcard(info);
		local reply = st.reply(stanza):add_child(st.deserialize(vCard));
		--module:log("debug", tostring(reply));
		session.send(reply);
	else
		module:log("debug", "reject setting vcard");
		session.send(st.error_reply(stanza, "auth", "forbidden"));
	end
	return true;
end

module:hook("iq/bare/vcard-temp:vCard", handle_vcard);
module:hook("iq/host/vcard-temp:vCard", handle_vcard);
