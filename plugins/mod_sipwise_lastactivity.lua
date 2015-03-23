-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- TODO: permanent storage
local st = require "util.stanza";
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local sessions = module:shared("sessions");

module:add_feature("jabber:iq:last");

local map = {};

-- lastactivity: any change of presence
module:hook("pre-presence/bare", function(event)
	local stanza = event.stanza;
	if not(stanza.attr.to) then
		local t = os.time();
		local s = stanza:child_with_name("status");
		s = s and #s.tags == 0 and s[1] or "";
		map[event.origin.username] = {s = s, t = t};
		module:log("debug", string.format("change of presence:%s from:%s",
			s, event.origin.username))
	end
end, 10);

local function msg_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local username = jid_split(stanza.attr.from) or origin.username;
	map[username] = {s = "online", t = os.time()};
	module:log("debug", string.format("%s from: %s",
		stanza.attr.type, username));
end

-- lastactivity: any message sent
module:hook("pre-message/bare", msg_handler);
module:hook("pre-message/full", msg_handler);

module:hook("iq/bare/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" then
		local username = jid_split(stanza.attr.to) or origin.username;
		if not stanza.attr.to or is_contact_subscribed(username, module.host, jid_bare(stanza.attr.from)) then
			local seconds, text = nil, "";
			if not sessions[origin.conn] and map[username] then
				seconds = tostring(os.difftime(os.time(), map[username].t));
				text = map[username].s;
			end
			origin.send(st.reply(stanza):tag('query', {xmlns='jabber:iq:last', seconds=seconds}):text(text));
		else
			origin.send(st.error_reply(stanza, 'auth', 'forbidden'));
		end
		return true;
	end
end);

module:save = function(self)
	return {map = map};
end
module:restore = function(self, data)
	map = data.map or {};
end
