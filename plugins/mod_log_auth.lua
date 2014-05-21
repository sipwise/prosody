-- Copyright (C) 2013 Kim Alvefur <zash@zash.se>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:hook("authentication-failure", function (event)
	module:log("info", "Failed authentication attempt (%s) from IP: %s", event.condition or "unknown-condition", event.session.ip or "?");
end);
