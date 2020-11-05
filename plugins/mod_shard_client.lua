-- Prosody IM
-- Copyright (C) 2015 Robert Norris <robn@robn.io>
-- Copyright (C) 2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:set_global();
local socket = require "socket"
local ut = require "ngcp.utils";
local logger = require "util.logger";
local st = require "util.stanza";
local new_xmpp_stream = require "util.xmppstream".new;
local wrapclient = require "net.server".wrapclient;
local log = module._log;
local shard_name = module:get_option("shard_name", nil);
if not shard_name then
    error("shard_name not configured", 0);
end
local opt_keepalives = module:get_option_boolean("shard_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));

local conns = {};
local queue = {};

local listener = {};

local sessions = module:shared("sessions");

local xmlns_shard = 'prosody:shard';
local stream_callbacks = { default_ns = xmlns_shard };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.error(session, error, data, _)
	if session.destroyed then return; end
	module:log("warn", "Error processing shard stream: %s", tostring(error));
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("warn", "External shard %s XML parse error: %s", tostring(session.host), tostring(data));
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

function stream_callbacks.streamclosed(session)
	session.log("debug", "Received </stream:stream>");
	session:close();
end

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

function listener.onconnect(conn)
    local shard = conn:ip();

	local session = { type = "shard", conn = conn, send = function (data) return conn:write(tostring(data)); end, shard = shard };

	-- Logging functions --
	local conn_name = "sc"..tostring(session):match("[a-f0-9]+$");
	session.log = logger.init(conn_name);
	session.close = session_close;

	if opt_keepalives then
		conn:setoption("keepalive", opt_keepalives);
	end

	session.log("info", "outgoing shard connection");

	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;

	function session.data(_, data)
		local ok, err = stream:feed(data);
		if ok then return; end
		module:log("debug", "Received invalid XML (%s) %d bytes: %s", tostring(err), #data, data:sub(1, 300):gsub("[\r\n]+", " "):gsub("[%z\1-\31]", "_"));
		session:close("not-well-formed");
	end

	session.dispatch_stanza = stream_callbacks.handlestanza;

	session.notopen = true;
	session.send(st.stanza("stream:stream", {
		to = conn:ip(),
		["xmlns:stream"] = 'http://etherx.jabber.org/streams';
		xmlns = xmlns_shard;
	}):top_tag());

    local _queue = queue[shard];
    for _,s in pairs(_queue) do
        conn:write(tostring(s));
    end
    queue[shard] = nil;

	sessions[conn] = session;
end
function listener.onincoming(conn, data)
	local session = sessions[conn];
	session.data(conn, data);
end
function listener.ondisconnect(conn, err)
	local session = sessions[conn];

	if (session) then
		(session.log or log)("info", "shard disconnected: %s (%s)", tostring(session.shard), tostring(err));
		if session.on_destroy then session:on_destroy(err); end
		sessions[conn] = nil;
		conns[session.shard] = nil;
		for k in pairs(session) do
			if k ~= "log" and k ~= "close" then
				session[k] = nil;
			end
		end
		session.destroyed = true;
	end

	module:log("error", "connection lost");
	module:fire_event("shard/disconnected", { reason = err, shard = conn:ip() });
end

local function connect(shard)
	local conn = socket.tcp ( )
	conn:settimeout ( 10 )
	local ok, err = conn:connect (shard, 7473)
	if not ok and err ~= "timeout" then
		return nil, err;
	end

	local handler, _ = wrapclient ( conn , shard , 7473 , listener , "*a")
	return handler;
end

module:hook_global("server-stopping", function(event)
	local reason = event.reason;
	for _, session in pairs(sessions) do
            session:close{ condition = "system-shutdown", text = reason };
    end
end, 1000);

local function handle_send(event)
    local shard = event.shard;
    local stanza = event.stanza;

    module:log("debug", "got stanza for shard "..shard)

    local conn = conns[shard];
    if conn == nil then
        module:log("debug", "connecting to "..shard.." for delivery");
        local err;
        conn, err = connect(shard);
        if not conn then
            module:log("error", "couldn't connect to "..shard..": "..err);
            module:fire_event("shard/error", {shard = shard, stanza = stanza});
            return;
        end
        conns[shard] = conn;
        queue[shard] = {};
    end
    if stanza.attr.via then
        local via = ut.explode(';', stanza.attr.via);
        module:log("debug", "via:%s", ut.table.tostring(via));
        if ut.table.contains(via, shard_name) then
            module:log("error", "loop detected, stanza[%s]", stanza);
            return;
        end
        table.insert(via, shard_name);
        stanza.attr.via = ut.implode(';', via);
    else
        stanza.attr.via = shard_name;
    end
    module:log("debug", "new via:%s", stanza.attr.via);

    local session = sessions[conn]
    if session == nil then
        table.insert(queue[shard], stanza)
    else
        conn:write(tostring(stanza));
    end
end

module:hook_global("shard/send", handle_send, 1000);
