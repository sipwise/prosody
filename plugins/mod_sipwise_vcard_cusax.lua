-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2013 Sipwise GmbH
-- 
-- This is a stripped down version of mod_vcard for returning
-- simply a vcard containing SIP URIs for phone/video of
-- the requested user.
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("sipwise_vcard_cusax");
local st = require "util.stanza";

module:add_feature("vcard-temp");

local function handle_vcard(event)
	module:log("debug", "handle_vcard");
	local session, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	if stanza.attr.type == "get" then
		local uri;
		if to then
			uri = to;
		else
			uri = session.username .. '@' .. session.host;
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
				{
					name = "NUMBER",
					attr = { xmlns = "vcard-temp" },
					"sip:" .. uri
				},
				{
					name = "VIDEO",
					attr = { xmlns = "vcard-temp" },
					"sip:" .. uri
				},
			}
		};
		session.send(st.reply(stanza):add_child(st.deserialize(vCard)));
	else
		module:log("debug", "reject setting vcard");
		session.send(st.error_reply(stanza, "auth", "forbidden"));
	end
	return true;
end

module:hook("iq/bare/vcard-temp:vCard", handle_vcard);
module:hook("iq/host/vcard-temp:vCard", handle_vcard);
