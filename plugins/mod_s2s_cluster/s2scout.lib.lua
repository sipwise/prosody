-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

--- Module containing all the logic for connecting to a remote server

local portmanager = require "core.portmanager";
local wrapclient = require "net.server".wrapclient;
local initialize_filters = require "util.filters".initialize;
local idna_to_ascii = require "util.encodings".idna.to_ascii;
local new_ip = require "util.ip".new_ip;
local rfc6724_dest = require "util.rfc6724".destination;
local socket = require "socket";
local t_insert, t_sort, ipairs = table.insert, table.sort, ipairs;
local local_addresses = require "util.net".local_addresses;

local s2sc_destroy_session = require "core.s2scmanager".destroy_session;

local log = module._log;

local sources = {};
local has_ipv4, has_ipv6;

local s2scout = {};

local s2sc_listener;


function s2scout.set_listener(listener)
	s2sc_listener = listener;
end

function s2scout.initiate_connection(host_session)
	initialize_filters(host_session);
	host_session.version = 1;

	-- Kick the connection attempting machine into life
	local connect_host = { addr=host_session.to_host, proto="IPv4" };
	host_session.to_host = host_session.from_host;
	if not s2scout.make_connect(host_session, connect_host, 15269) then
		-- Intentionally not returning here, the
		-- session is needed, connected or not
		s2sc_destroy_session(host_session);
	end

	if not host_session.sends2sc then
		host_session.log("debug", "adding sends2sc")
		-- A sends2sc which buffers data (until the stream is opened)
		-- note that data in this buffer will be sent before the stream is authed
		-- and will not be ack'd in any way, successful or otherwise
		local buffer;
		function host_session.sends2sc(data)
			if not buffer then
				buffer = {};
				host_session.send_buffer = buffer;
			end
			log("debug", "[sends2sc] Buffering data on unconnected s2scout to %s", tostring(host_session.to_host));
			buffer[#buffer+1] = data;
			log("debug", "[sends2sc] Buffered item %d: %s", #buffer, tostring(data));
		end
	end
end

function s2scout.make_connect(host_session, connect_host, connect_port)
	(host_session.log or log)("info", "Beginning new connection attempt to %s ([%s]:%d)", host_session.to_host, connect_host.addr, connect_port);

	-- Reset secure flag in case this is another
	-- connection attempt after a failed STARTTLS
	host_session.secure = nil;

	local conn, handler;
	local proto = connect_host.proto;
	if proto == "IPv4" then
		conn, handler = socket.tcp();
	elseif proto == "IPv6" and socket.tcp6 then
		conn, handler = socket.tcp6();
	else
		handler = "Unsupported protocol: "..tostring(proto);
	end

	if not conn then
		log("warn", "Failed to create outgoing connection, system error: %s", handler);
		return false, handler;
	end

	conn:settimeout(0);
	local success, err = conn:connect(connect_host.addr, connect_port);
	if not success and err ~= "timeout" then
		log("warn", "s2sc connect() to %s (%s:%d) failed: %s", host_session.to_host, connect_host.addr, connect_port, err);
		return false, err;
	end

	conn = wrapclient(conn, connect_host.addr, connect_port, s2sc_listener, "*a");
	host_session.conn = conn;

	local filter = initialize_filters(host_session);
	local w, log = conn.write, host_session.log;
	host_session.sends2sc = function (t)
		log("debug", "sends2sc: sending[%s (%s:%d)]: %s",
			host_session.to_host, connect_host.addr, connect_port,
			(t.top_tag and t:top_tag()) or t:match("^[^>]*>?"));
		if t.name then
			t = filter("stanzas/out", t);
		end
		if t then
			t = filter("bytes/out", tostring(t));
			if t then
				return w(conn, tostring(t));
			end
		end
	end
	-- Register this outgoing connection so that xmppserver_listener knows about it
	-- otherwise it will assume it is a new incoming connection
	s2sc_listener.register_outgoing(conn, host_session);

	log("debug", "Connection attempt in progress...");
	return true;
end

module:hook_global("service-added", function (event)
	if event.name ~= "s2sc" then return end

	local s2sc_sources = portmanager.get_active_services():get("s2sc");
	if not s2sc_sources then
		module:log("warn", "s2sc not listening on any ports, outgoing connections may fail");
		return;
	end
	for source, _ in pairs(s2sc_sources) do
		if source == "*" or source == "0.0.0.0" then
			for _, addr in ipairs(local_addresses("ipv4", true)) do
				sources[#sources + 1] = new_ip(addr, "IPv4");
			end
		elseif source == "::" then
			for _, addr in ipairs(local_addresses("ipv6", true)) do
				sources[#sources + 1] = new_ip(addr, "IPv6");
			end
		else
			sources[#sources + 1] = new_ip(source, (source:find(":") and "IPv6") or "IPv4");
		end
	end
	for i = 1,#sources do
		if sources[i].proto == "IPv6" then
			has_ipv6 = true;
		elseif sources[i].proto == "IPv4" then
			has_ipv4 = true;
		end
	end
	if not (has_ipv4 or has_ipv6)  then
		module:log("warn", "No local IPv4 or IPv6 addresses detected, outgoing connections may fail");
	end
end);

return s2scout;
