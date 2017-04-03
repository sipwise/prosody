-- Prosody IM
-- Copyright (C) 2017 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
local defaults = {
	force_persistent = true,
};
local params = module:get_option("muc_config", defaults);

local function handle_muc_config(event)
	local room, fields = event.room, event.fields;
	local name = fields['muc#roomconfig_roomname'] or room:get_name();
	local persistent = fields['muc#roomconfig_persistentroom'];
	if params.force_persistent and not persistent then
		fields['muc#roomconfig_persistentroom'] = true;
		event.changed = true;
		module:log("debug", "persistent room[%s] forced", name);
	end
end

module:hook("muc-config-submitted", handle_muc_config, 1);
