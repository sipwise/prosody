-- Prosody IM
-- Copyright (C) 2015 Robert Norris <robn@robn.io>
-- Copyright (C) 2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();
local logger = require "util.logger"
local log = logger.init("shard_server");
local st = require "util.stanza";
local jid_split = require "util.jid".split;

local new_xmpp_stream = require "util.xmppstream".new;
local uuid_gen = require "util.uuid".generate;

local core_process_stanza = prosody.core_process_stanza;
local hosts = prosody.hosts;

local traceback = debug.traceback;

local shard_name = module:get_option("shard_name", nil);
if not shard_name then
    error("shard_name not configured", 0);
end

local opt_keepalives = module:get_option_boolean("shard_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));

local sessions = module:shared("sessions");

--- Network and stream part ---

local xmlns_shard = 'prosody:shard';

local listener = {};

--- Callbacks/data for xmppstream to handle streams for us ---

local stream_callbacks = { default_ns = xmlns_shard };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.error(session, error, data, _)
	if session.destroyed then return; end
	module:log("warn", "Error processing component stream: %s", tostring(error));
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("warn", "External component %s XML parse error: %s", tostring(session.host), tostring(data));
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:children() do
			if child.attr.xmlns == xmlns_xmpp_streams then
				if child.name ~= "text" then
					condition = child.name;
				else
					text = child:get_text();
				end
				if condition ~= "undefined-condition" and text then
					break;
				end
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

function stream_callbacks.streamopened(session, attr)
	if attr.to ~= shard_name then
		session:close{ condition = "host-unknown", text = "unknown shard name "..tostring(attr.to) };
		return;
	end
	session.host = attr.to;
	session.streamid = uuid_gen();
	session.notopen = nil;
	-- Return stream header
	session:open_stream();
end

function stream_callbacks.streamclosed(session)
	session.log("debug", "Received </stream:stream>");
	session:close();
end

local function handleerr(err) log("error", "Traceback[component]: %s", traceback(tostring(err), 2)); end
function stream_callbacks.handlestanza(_, stanza)
	local to = stanza.attr.to;
	local _, host = jid_split(to);

	if not host then return end

	local h = hosts[host];
	local nh = {};
	for k,v in pairs(h) do nh[k] = v; end
	nh.type = "component";

	return xpcall(function () return core_process_stanza(nh, stanza) end, handleerr);
end

--- Closing a component connection
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason)
	if session.destroyed then return; end
	if session.conn then
		if session.notopen then
			session.send("<?xml version='1.0'?>");
			session.send(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				module:log("info", "Disconnecting component, <stream:error> is: %s", reason);
				session.send(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					module:log("info", "Disconnecting component, <stream:error> is: %s", tostring(stanza));
					session.send(stanza);
				elseif reason.name then -- a stanza
					module:log("info", "Disconnecting component, <stream:error> is: %s", tostring(reason));
					session.send(reason);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn:close();
		listener.ondisconnect(session.conn, "stream error");
	end
end

--- Component connlistener

function listener.onconnect(conn)
	local _send = conn.write;
	local session = { type = "shard", conn = conn, send = function (data) return _send(conn, tostring(data)); end };

	-- Logging functions --
	local conn_name = "ss"..tostring(session):match("[a-f0-9]+$");
	session.log = logger.init(conn_name);
	session.close = session_close;

	if opt_keepalives then
		conn:setoption("keepalive", opt_keepalives);
	end

	session.log("info", "incoming shard connection");

	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;

	session.notopen = true;

	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end

	function session.data(_, data)
		local ok, err = stream:feed(data);
		if ok then return; end
		module:log("debug", "Received invalid XML (%s) %d bytes: %s", tostring(err), #data, data:sub(1, 300):gsub("[\r\n]+", " "):gsub("[%z\1-\31]", "_"));
		session:close("not-well-formed");
	end

	session.dispatch_stanza = stream_callbacks.handlestanza;

	sessions[conn] = session;
end
function listener.onincoming(conn, data)
	local session = sessions[conn];
	session.data(conn, data);
end
function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "component disconnected: %s (%s)", tostring(session.host), tostring(err));
		if session.on_destroy then session:on_destroy(err); end
		sessions[conn] = nil;
		for k in pairs(session) do
			if k ~= "log" and k ~= "close" then
				session[k] = nil;
			end
		end
		session.destroyed = true;
	end
end

function listener.ondetach(conn)
	sessions[conn] = nil;
end

module:provides("net", {
	name = "shard";
	private = true;
	listener = listener;
	default_port = 7473;
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])"..xmlns_shard.."%1.*>";
	};
});
