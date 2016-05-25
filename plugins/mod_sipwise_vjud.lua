--
-- Copyright (C) 2013-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:depends("disco");

local ut_jid = require "util.jid";
local mod_sql = module:require("sql");
local st = require "util.stanza";
local template = require "util.template";
local rex = require "rex_pcre";
local prosodyctl = require "util.prosodyctl"
local dataforms_new = require "util.dataforms".new;

local form_layout = dataforms_new{
  title= 'User Directory Search';
  instructions = 'Please provide the following information to search for subscribers';
  {
    type  = 'text-single',
    label = 'e164 Phone number',
    name  = 'e164',
    required = false,
  },
};

local get_reply = template[[
  <query xmlns='jabber:iq:search'>
    <instructions>Use the enclosed form to search</instructions>
    <x xmlns='jabber:x:data' type='form'>
      <title>User Directory Search</title>
      <instructions>Please provide the following information to search for subscribers</instructions>
      <field type='hidden' var='FORM_TYPE'>
        <value>jabber:iq:search</value>
      </field>
      <field type='text-single'
             label='e164 Phone number'
             var='e164'/>
    </x>
    <nick/>
  </query>
]].apply({});

local usr_replacements_query = [[
SELECT vrr.match_pattern, vrr.replace_pattern FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_subscribers vs ON vs.id = vup.subscriber_id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vs.domain_id
  LEFT JOIN provisioning.voip_rewrite_rule_sets vrrs ON vrrs.callee_in_dpid = vup.value
  LEFT JOIN provisioning.voip_rewrite_rules vrr ON vrr.set_id = vrrs.id AND vrr.direction = 'in' AND vrr.field = 'callee'
WHERE vp.attribute = 'rewrite_callee_in_dpid' AND vs.username = ? AND vd.domain = ?
  ORDER BY vrr.priority ASC;
]];

local dom_replacements_query = [[
SELECT vrr.match_pattern, vrr.replace_pattern FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_dom_preferences vdp ON vdp.attribute_id = vp.id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vdp.domain_id
  LEFT JOIN provisioning.voip_rewrite_rule_sets vrrs ON vrrs.callee_in_dpid = vdp.value
  LEFT JOIN provisioning.voip_rewrite_rules vrr ON vrr.set_id = vrrs.id AND vrr.direction = 'in' AND vrr.field = 'callee'
WHERE vp.attribute = 'rewrite_callee_in_dpid'  AND vd.domain = ?
  ORDER BY vrr.priority ASC;
]];

local locale_query = [[
SELECT vp.attribute, vup.value FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_subscribers vs ON vs.id = vup.subscriber_id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vs.domain_id
WHERE (vp.attribute = 'ac' or vp.attribute = 'cc')
  AND vs.username = ?
  AND vd.domain = ?;
]];

local lookup_query = [[
SELECT username,domain FROM kamailio.dbaliases
WHERE alias_username=?;
]];

local params = module:get_option("auth_sql", {
	driver = "MySQL",
	database = "provisioning",
	username = "prosody",
	password = "PW_PROSODY",
	host = "localhost"
});
local engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");

local function normalize_number(user, host, number)
	local locale_info = {};
	for row in engine:select(locale_query, user, host) do
		locale_info["caller_"..row[1]] = row[2];
	end

	local replacement_regexes = {};
	local usr_pref = 0;
	for row in engine:select(usr_replacements_query, user, host) do
		usr_pref = 1;
		module:log("debug", "user rewrite_callee_in_dpid preference found");
		local patt, repl = row[1], row[2]
			:gsub("%$avp%(s:([a-zA-Z_]+)%)", locale_info)
			:gsub("\\", "%%"):gsub("%%%%", "\\");
		table.insert(replacement_regexes, { patt, repl });
	end
	if usr_pref == 0 then
		for row in engine:select(dom_replacements_query, host) do
			module:log("debug", "domain rewrite_callee_in_dpid preference found");
			local patt, repl = row[1], row[2]
				:gsub("%$avp%(s:([a-zA-Z_]+)%)", locale_info)
				:gsub("\\", "%%"):gsub("%%%%", "\\");
			table.insert(replacement_regexes, { patt, repl });
		end
	end

	for _, rule in ipairs(replacement_regexes) do
		local new_number, n_matches = rex.gsub(number, rule[1], rule[2]);
		if n_matches > 0 then
			module:log("debug", "rule [%s] matched [%s]->[%s]",
				tostring(rule[1]), tostring(number), tostring(new_number));
			number = new_number;
			break;
		end
	end
	return number;
end

local function search_by_number(number)
	local results = {};
	module:log("debug", "search jids with number:[%s]", tostring(number));
	for result in engine:select(lookup_query, number) do
		table.insert(results, result[1].."@"..result[2]);
	end
	return results;
end

function module.command(arg)
	local warn = prosodyctl.show_warning;
	local command = arg[1];
	if not command then
		warn("Valid subcommands: normalize");
		return 0;
	end
	table.remove(arg, 1);
	if command == "normalize" then
		if #arg ~= 2 then
			warn("Usage: normalize USER@HOST NUMBER");
			return 1;
		end
		local user_jid, number = arg[1], arg[2];
		local user, host = ut_jid.prepped_split(user_jid);
		if not (user and host) then
			warn("Invalid JID: "..user_jid);
			return 1;
		end
		print(normalize_number(user, host, number));
	elseif command == "query" then
		if #arg ~= 1 then
			warn("Usage: query NUMBER");
			warn("  NUMBER must be normalized (see 'normalize' command)");
			return 1;
		end
		local results = search_by_number(arg[1]);
		for _, jid in ipairs(results) do
			print("", jid);
		end
	end
	return 0;
end

if module:get_host_type() ~= "component" then
	error("Don't load mod_sipwise_vjud manually,"..
		" it should be for a component", 0);
end

module:add_feature("jabber:iq:search");
module:add_feature("jabber:x:data"); -- dataforms
module:hook("iq/host/jabber:iq:search:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	module:log("debug", "stanza[%s]", tostring(stanza));
	if stanza.attr.type == "get" then
		return origin.send(st.reply(stanza):add_child(get_reply));
	else

		local user, host = ut_jid.split(stanza.attr.from);
		local query = stanza:get_child("query",'jabber:iq:search');
		local form_stanza = query:get_child("x",'jabber:x:data');
		local reply;
		local search_number = stanza.tags[1]:get_child_text("nick");

		if form_stanza then
			local form_data, form_errors = form_layout:data(form_stanza);
			if form_errors and form_errors['e164'] then
				reply = st.error_reply(stanza, "modify",
					"bad-request", "e164: "..form_errors['e164']);
				return origin.send(reply);
			else
				search_number = form_data['e164'] or search_number;
			end
		end

		if search_number then
			-- Reconnect to DB if necessary
			if not engine.conn:ping() then
				engine.conn = nil;
				engine:connect();
			end

			local number = normalize_number(user, host, search_number);
			reply = st.reply(stanza):query("jabber:iq:search");


			for _, jid in ipairs(search_by_number(number)) do
				reply:tag("item", { jid = jid }):up();
			end
		else
			reply = st.error_reply(stanza, "modify",
					"bad-request", "no nick or e164 field found");
		end

		return origin.send(reply);
	end
end);
