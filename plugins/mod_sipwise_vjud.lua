--
-- Copyright (C) 2013-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:depends("disco");
local softreq = require "util.dependencies".softreq;
local ut_jid = require "util.jid";
local sql = require "util.sql";
local st = require "util.stanza";
local template = require "util.template";
local prosodyctl = require "util.prosodyctl"
local dataforms_new = require "util.dataforms".new;
local ut = require "ngcp.utils";
local hosts = prosody.hosts;
local rex = softreq "rex_pcre";
if not rex then
  rex = require "rex_pcre2";
end

local form_layout = dataforms_new{
  title= 'User Directory Search';
  instructions = 'Please provide the following information to search for subscribers';
  {
    type  = 'text-single',
    label = 'e164 Phone number',
    name  = 'e164',
    required = false,
  },
  {
    type  = 'text-single',
    label = 'domain',
    name  = 'domain',
    required = false,
  },
};

local form_item = template[[
      <item>
        <field var='{name}'>
          <value>{value}</value>
        </field>
      </item>
]];

local form_reply = {
	domain = template[[
  <query xmlns='jabber:iq:search'>
    <x xmlns='jabber:x:data' type='result'>
      <field type='hidden' var='FORM_TYPE'>
        <value>jabber:iq:search</value>
      </field>
      <reported>
        <field type='text-single'
             label='domain'
             var='domain'/>
      </reported>
    </x>
  </query>
]],
	e164 = template[[
  <query xmlns='jabber:iq:search'>
    <x xmlns='jabber:x:data' type='result'>
      <field type='hidden' var='FORM_TYPE'>
        <value>jabber:iq:search</value>
      </field>
      <reported>
        <field type='text-single'
             label='e164 Phone number'
             var='e164'/>
      </reported>
    </x>
  </query>
]],
  form = template[[
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
      <field type='text-single'
             label='domain'
             var='domain'/>
    </x>
    <nick/>
  </query>
]]
};

local usr_replacements_query = [[
SELECT vrr.match_pattern, vrr.replace_pattern FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_usr_preferences vup ON vup.attribute_id = vp.id
  LEFT JOIN provisioning.voip_subscribers vs ON vs.id = vup.subscriber_id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vs.domain_id
  LEFT JOIN provisioning.voip_rewrite_rule_sets vrrs ON vrrs.callee_in_dpid = vup.value
  LEFT JOIN provisioning.voip_rewrite_rules vrr ON vrr.set_id = vrrs.id
   AND vrr.direction = 'in'
   AND vrr.field = 'callee'
WHERE vp.attribute = 'rewrite_callee_in_dpid' AND vs.username = ? AND vd.domain = ?
  ORDER BY vrr.priority ASC;
]];

local dom_replacements_query = [[
SELECT vrr.match_pattern, vrr.replace_pattern FROM provisioning.voip_preferences vp
  LEFT JOIN provisioning.voip_dom_preferences vdp ON vdp.attribute_id = vp.id
  LEFT JOIN provisioning.voip_domains vd ON vd.id = vdp.domain_id
  LEFT JOIN provisioning.voip_rewrite_rule_sets vrrs ON vrrs.callee_in_dpid = vdp.value
  LEFT JOIN provisioning.voip_rewrite_rules vrr ON vrr.set_id = vrrs.id
   AND vrr.direction = 'in' AND vrr.field = 'callee'
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

local default_params = module:get_option("sql");
local engine;

-- Reconnect to DB if necessary
local function reconect_check()
	if not engine.conn:ping() then
		engine.conn = nil;
		engine:connect();
	end
end

local function normalize_number(user, host, number)
	local locale_info = {};
	reconect_check();
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
	reconect_check();
	module:log("debug", "search jids with number:[%s]", tostring(number));
	for result in engine:select(lookup_query, number) do
		table.insert(results, result[1].."@"..result[2]);
	end
	return results;
end

local function get_dataform_items(vals, fieldname)
	local res = {};

	for _,v in ipairs(vals) do
		table.insert(res, form_item.apply({ name = fieldname, value = v }));
	end
	return res;
end

local function search_domains(dom)
	local hosts_keys = ut.table.keys(hosts);
	local res = {};

	module:log("debug", "search for domain: %s", tostring(dom));
	if dom == '*' then
		res = get_dataform_items(hosts_keys, 'domain');
	elseif ut.table.contains(hosts_keys, dom) then
		res = get_dataform_items({dom,}, 'domain');
	end
	return res;
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

local function append_x_items(form, values, reply)
	local x = form:get_child('x', 'jabber:x:data');
	for _, v in ipairs(values) do
		x:add_child(v):up();
	end
	reply:add_child(x);
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
		return origin.send(st.reply(stanza):add_child(form_reply.form.apply({})));
	else

		local user, host = ut_jid.split(stanza.attr.from);
		local query = stanza:get_child("query",'jabber:iq:search');
		local form_stanza = query:get_child("x",'jabber:x:data');
		local reply;
		local search_number = stanza.tags[1]:get_child_text("nick");
		local search_domain

		if form_stanza then
			local form_data, form_errors = form_layout:data(form_stanza);
			if form_errors and form_errors['e164'] then
				reply = st.error_reply(stanza, "modify",
					"bad-request", "e164: "..form_errors['e164']);
				return origin.send(reply);
			else
				search_number = form_data['e164'] or search_number;
				search_domain = form_data['domain'];
			end
		end

		if search_number then
			local number = normalize_number(user, host, search_number);
			local data = search_by_number(number);
			reply = st.reply(stanza):query("jabber:iq:search");
			if form_stanza then
				append_x_items(form_reply.e164.apply({}),
					get_dataform_items(data, 'e164'), reply);
			else
				for _, jid in ipairs(data) do
					reply:tag("item", { jid = jid }):up();
				end
			end
		elseif search_domain then
			reply = st.reply(stanza):query("jabber:iq:search");
			append_x_items(form_reply.domain.apply({}),
				search_domains(search_domain), reply);
		else
			reply = st.error_reply(stanza, "modify",
					"bad-request", "no domain, nick or e164 field found");
		end

		return origin.send(reply);
	end
end);

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
	module:log("debug", "load OK");
end
