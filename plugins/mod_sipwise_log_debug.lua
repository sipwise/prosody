-- Copyright (C) 2015 Sipwise GmbH <development@sipwise.com>
--
-- enable log stanzas/[in|out] by jid
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:set_global();
local jid = require "util.jid";
local add_filter = require "util.filters".add_filter;
local ut = require "ngcp.utils";
local log = module._log;

local config_default = {
	level = "debug",         -- log level
	prefix_out = "Sent",
	prefix_in = "Received",
	jids = {},               -- jids to log
	filter = {'*'}           -- 'message', 'iq'
};
local config

local function filter_stanza(stanza)
	if ut.table.contains(config.filter, '*') then
		return true
	end
	for _,v in pairs(config.filter) do
		if stanza.name == v then
			return true
		end
		if stanza:get_child(v) then
			return true
		end
	end
	return false
end

local function log_stanza(stanza, session, prefix)
	if filter_stanza(stanza) then
		session.log(config.level, "%s[%s]: %s", prefix, session.full_jid,
			tostring(stanza))
		return stanza
	end
	return stanza
end

local function log_in_stanza (stanza, session)
	return log_stanza(stanza, session,
			config.prefix_in or config_default.prefix_in)
end

local function log_out_stanza (stanza, session)
	return log_stanza(stanza, session,
			config.prefix_out or config_default.prefix_out)
end


local function resource_bind(event)
	local session = event.session;
	local node, domain, _ = jid.split(session.full_jid);
	local bare_jid = node.."@"..domain;

	if ut.table.contains(config.jids, bare_jid) then
		add_filter(session, "stanzas/out", log_out_stanza, 1000);
		add_filter(session, "stanzas/in", log_in_stanza, 1000);
		module:log("info", "log_debug activated for %s for filter %s",
			session.full_jid, ut.table.tostring(config.filter))
	end
end

function module.load()
	config = module:get_option("log_debug", config_default);
	log("info", "jids: %s", ut.table.tostring(config.jids))
end

function module.add_host(module)
	module:hook("resource-bind", resource_bind, 200);
end
