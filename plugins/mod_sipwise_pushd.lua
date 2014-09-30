--
-- Copyright (C) 2014 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local mod_sql = module:require("sql");
local format = string.format;
local jid_split = require "util.jid".split;

local pushd_config = {
	url = "https://127.0.0.1:8080/push",
	query = "caller=%s@%s&callee=%s&domain=%s",
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

local function process_response(response, code, request)
	if code >= 200 and code < 299 then
		module:log("debug", "pushd response OK[%s] %s",
			tostring(code), response);
	else
		module:log("error", "pushd response KO[%s] %s",
			tostring(code), response);
	end
end

local function push_enable(username, domain)
	local row
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

local function handle_offline(event)
	module:log("debug", "handle_offline");
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	local from = stanza.attr.from;
	local node, host;
	local caller = { username = 'unknow', host = 'unknown.local' };
	local http_options = {
		method = "POST",
		body = "",
	}

	if from then
		caller.username, caller.host = jid_split(from);
	end

	if to then
		node, host = jid_split(to);
		if push_enable(node, host) then
			http_options.body = format(pushd_config.query,
				origin.username or caller.username,
				origin.host or caller.host, node, host);
			module:log("debug", "Sending http pushd request: %s data: %s",
				pushd_config.url, http_options.body);
			http.request(pushd_config.url, http_options, process_response);
		else
			module:log("debug", "no mobile_push_enable pref set for %s", to);
		end
	end
end

module:hook("message/offline/handle", handle_offline, 20);

function module.load()
	pushd_config = module:get_option("pushd_config", pushd_config);
	sql_config   = module:get_option("auth_sql", sql_config);
	engine = mod_sql:create_engine(sql_config);
	engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");
	module:log("info", "load OK");
end
