local nodeprep = require "util.encodings".stringprep.nodeprep;
local jid_split = require "util.jid".split;
local sql = module:require("sql");
local st = require "util.stanza";
local template = require "util.template";
local array = require "util.array";
local rex = require "rex_pcre";

local get_reply = template[[
  <query xmlns='jabber:iq:search'>
    <instructions>Please enter a phone number</instructions>
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

local mod_sql = module:require("sql");
local params = module:get_option("auth_sql", {
	driver = "MySQL", 
	database = "provisioning", 
	username = "prosody", 
	password = "PW_PROSODY", 
	host = "localhost" 
});
engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");

function normalize_number(user, host, number)
	local locale_info = {};
	for row in engine:select(locale_query, user, host) do
		locale_info["caller_"..row[1]] = row[2];
	end

	local replacement_regexes = {};
	local usr_pref = 0;
	for row in engine:select(usr_replacements_query, user, host) do
		usr_pref = 1;
		local patt, repl = row[1], row[2]
			:gsub("%$avp%(s:([a-zA-Z_]+)%)", locale_info)
			:gsub("\\", "%%"):gsub("%%%%", "\\");
		table.insert(replacement_regexes, { patt, repl });
	end
	if usr_pref == 0 then
		for row in engine:select(dom_replacements_query, host) do
			local patt, repl = row[1], row[2]
				:gsub("%$avp%(s:([a-zA-Z_]+)%)", locale_info)
				:gsub("\\", "%%"):gsub("%%%%", "\\");
			table.insert(replacement_regexes, { patt, repl });
		end
	end
	
	for _, rule in ipairs(replacement_regexes) do
		local new_number, n_matches = rex.gsub(number, rule[1], rule[2]);
		if n_matches > 0 then
			number = new_number;
			break;
		end
	end
	return number;
end

function search_by_number(number)
	local results = {};
	for result in engine:select(lookup_query, number) do
		table.insert(results, result[1].."@"..result[2]);
	end
	return results;
end

module:depends("disco");
module:add_feature("jabber:iq:search");

module:hook("iq/host/jabber:iq:search:query", function(event)
	local origin, stanza = event.origin, event.stanza;

	if stanza.attr.type == "get" then
		return origin.send(st.reply(stanza):add_child(get_reply));
	else
		local user, host = jid_split(stanza.attr.from);
		local number = stanza.tags[1]:get_child_text("nick");

		-- Reconnect to DB if necessary
		if not engine.conn:ping() then
			engine.conn = nil;
			engine:connect();
		end

		number = normalize_number(user, host, number);

		local reply = st.reply(stanza):query("jabber:iq:search");

		for _, jid in ipairs(search_by_number(number)) do
			reply:tag("item", { jid = jid }):up();
		end

		return origin.send(reply);
	end
end);

function module.command(arg)
	local jid = require "util.jid";
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
		local user, host = jid.prepped_split(user_jid);
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
