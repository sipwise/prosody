-- Prosody IM
-- Copyright (C) 2012 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local add_filter = require "util.filters".add_filter;
local sha1 = require "util.hashes".sha1;
local base64 = require "util.encodings".base64.encode;
local softreq = require "util.dependencies".softreq;
local portmanager = require "core.portmanager";

local bit;
pcall(function() bit = require"bit"; end);
bit = bit or softreq"bit32"
if not bit then module:log("error", "No bit module found. Either LuaJIT 2, lua-bitop or Lua 5.2 is required"); end
local band = bit.band;
local bxor = bit.bxor;
local rshift = bit.rshift;

local cross_domain = module:get_option("cross_domain_websocket");
if cross_domain then
	if cross_domain == true then
		cross_domain = "*";
	elseif type(cross_domain) == "table" then
		cross_domain = table.concat(cross_domain, ", ");
	end
	if type(cross_domain) ~= "string" then
		cross_domain = nil;
	end
end

module:depends("c2s")
local sessions = module:shared("c2s/sessions");
local c2s_listener = portmanager.get_service("c2s").listener;

-- Websocket helpers
local function parse_frame(frame)
	local result = {};
	local pos = 1;
	local length_bytes = 0;
	local counter = 0;
	local tmp_byte;

	if #frame < 2 then return; end

	tmp_byte = string.byte(frame, pos);
	result.FIN = band(tmp_byte, 0x80) > 0;
	result.RSV1 = band(tmp_byte, 0x40) > 0;
	result.RSV2 = band(tmp_byte, 0x20) > 0;
	result.RSV3 = band(tmp_byte, 0x10) > 0;
	result.opcode = band(tmp_byte, 0x0F);

	pos = pos + 1;
	tmp_byte = string.byte(frame, pos);
	result.MASK = band(tmp_byte, 0x80) > 0;
	result.length = band(tmp_byte, 0x7F);

	if result.length == 126 then
		length_bytes = 2;
		result.length = 0;
	elseif result.length == 127 then
		length_bytes = 8;
		result.length = 0;
	end

	if #frame < (2 + length_bytes) then return; end

	for i = 1, length_bytes do
		pos = pos + 1;
		result.length = result.length * 256 + string.byte(frame, pos);
	end

	if #frame < (2 + length_bytes + (result.MASK and 4 or 0) + result.length) then return; end

	if result.MASK then
		result.key = {string.byte(frame, pos+1), string.byte(frame, pos+2),
				string.byte(frame, pos+3), string.byte(frame, pos+4)}

		pos = pos + 5;
		result.data = "";
		for i = pos, pos + result.length - 1 do
			result.data = result.data .. string.char(bxor(result.key[counter+1], string.byte(frame, i)));
			counter = (counter + 1) % 4;
		end
	else
		result.data = frame:sub(pos + 1, pos + result.length);
	end

	return result, 2 + length_bytes + (result.MASK and 4 or 0) + result.length;
end

local function build_frame(desc)
	local length;
	local result = "";
	local data = desc.data or "";

	result = result .. string.char(0x80 * (desc.FIN and 1 or 0) + desc.opcode);

	length = #data;
	if length <= 125 then -- 7-bit length
		result = result .. string.char(length);
	elseif length <= 0xFFFF then -- 2-byte length
		result = result .. string.char(126);
		result = result .. string.char(rshift(length, 8)) .. string.char(length%0x100);
	else -- 8-byte length
		result = result .. string.char(127);
		for i = 7, 0, -1 do
			result = result .. string.char(rshift(length, 8*i) % 0x100);
		end
	end

	result = result .. data;

	return result;
end

--- Filter stuff
function handle_request(event, path)
	local request, response = event.request, event.response;
	local conn = response.conn;

	if not request.headers.sec_websocket_key then
		response.headers.content_type = "text/html";
		return [[<!DOCTYPE html><html><head><title>Websocket</title></head><body>
			<p>It works! Now point your WebSocket client to this URL to connect to Prosody.</p>
			</body></html>]];
	end

	local wants_xmpp = false;
	(request.headers.sec_websocket_protocol or ""):gsub("([^,]*),?", function (proto)
		if proto == "xmpp" then wants_xmpp = true; end
	end);

	if not wants_xmpp then
		return 501;
	end

	local function websocket_close(code, message)
		local data = string.char(rshift(code, 8)) .. string.char(code%0x100) .. message;
		conn:write(build_frame({opcode = 0x8, FIN = true, data = data}));
		conn:close();
	end

	local dataBuffer;
	local function handle_frame(frame)
		module:log("debug", "Websocket received: %s (%i bytes)", frame.data, #frame.data);

		-- Error cases
		if frame.RSV1 or frame.RSV2 or frame.RSV3 then -- Reserved bits non zero
			websocket_close(1002, "Reserved bits not zero");
			return false;
		end

		if frame.opcode >= 0x8 and frame.length > 125 then -- Control frame with too much payload
			websocket_close(1002, "Payload too large");
			return false;
		end

		if frame.opcode >= 0x8 and not frame.FIN then -- Fragmented control frame
			websocket_close(1002, "Fragmented control frame");
			return false;
		end

		if (frame.opcode > 0x2 and frame.opcode < 0x8) or (frame.opcode > 0xA) then
			websocket_close(1002, "Reserved opcode");
			return false;
		end

		if frame.opcode == 0x0 and not dataBuffer then
			websocket_close(1002, "Unexpected continuation frame");
			return false;
		end

		if (frame.opcode == 0x1 or frame.opcode == 0x2) and dataBuffer then
			websocket_close(1002, "Continuation frame expected");
			return false;
		end

		-- Valid cases
		if frame.opcode == 0x0 then -- Continuation frame
			dataBuffer = dataBuffer .. frame.data;
		elseif frame.opcode == 0x1 then -- Text frame
			dataBuffer = frame.data;
		elseif frame.opcode == 0x2 then -- Binary frame
			websocket_close(1003, "Only text frames are supported");
			return;
		elseif frame.opcode == 0x8 then -- Close request
			websocket_close(1000, "Goodbye");
			return;
		elseif frame.opcode == 0x9 then -- Ping frame
			frame.opcode = 0xA;
			conn:write(build_frame(frame));
			return "";
		else
			log("warn", "Received frame with unsupported opcode %i", frame.opcode);
			return "";
		end

		if frame.FIN then
			data = dataBuffer;
			dataBuffer = nil;

			return data;
		end
		return "";
	end

	conn:setlistener(c2s_listener);
	c2s_listener.onconnect(conn);

	local frameBuffer = "";
	add_filter(sessions[conn], "bytes/in", function(data)
		local cache = "";
		frameBuffer = frameBuffer .. data;
		local frame, length = parse_frame(frameBuffer);

		while frame do
			frameBuffer = frameBuffer:sub(length + 1);
			local result = handle_frame(frame);
			if not result then return; end
			cache = cache .. result;
			frame, length = parse_frame(frameBuffer);
		end
		return cache;

	end);

	add_filter(sessions[conn], "bytes/out", function(data)
		return build_frame({ FIN = true, opcode = 0x01, data = tostring(data)});
	end);

	response.status_code = 101;
	response.headers.upgrade = "websocket";
	response.headers.connection = "Upgrade";
	response.headers.sec_webSocket_accept = base64(sha1(request.headers.sec_websocket_key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
	response.headers.sec_webSocket_protocol = "xmpp";
	response.headers.access_control_allow_origin = cross_domain;

	return "";
end

function module.add_host(module)
	module:depends("http");
	module:provides("http", {
		name = "websocket";
		default_path = "xmpp-websocket";
		route = {
			["GET"] = handle_request;
			["GET /"] = handle_request;
		};
	});
end
