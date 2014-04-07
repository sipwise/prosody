-- Prosody IM
-- Copyright (C) 2014 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();
module:depends("sipwise_redis_sessions");

local st = require "util.stanza";
local ut = require "util.table";
local jid_split = require "util.jid".split;
local jid_prepped_split = require "util.jid".prepped_split;

local redis_sessions = module:shared("/*/sipwise_redis_sessions/redis_sessions");
local cluster = module:shared("cluster");
local core = {
	process_stanza = prosody.core_process_stanza,
	route_stanza = prosody.core_route_stanza,
	post_stanza = prosody.core_post_stanza,
	hosts = prosody.hosts
};

local cluster_config = {
	me = "localhost",
	hosts = {},
	dialback_secret = nil
};

local function handle_unhandled_stanza(host, origin, stanza)
	local name, xmlns, origin_type = stanza.name, stanza.attr.xmlns or "jabber:client", origin.type;
	if name == "iq" and xmlns == "jabber:client" then
		if stanza.attr.type == "get" or stanza.attr.type == "set" then
			xmlns = stanza.tags[1].attr.xmlns or "jabber:client";
			log("debug", "Stanza of type %s from %s has xmlns: %s", name, origin_type, xmlns);
		else
			log("debug", "Discarding %s from %s of type: %s", name, origin_type, stanza.attr.type);
			return true;
		end
	end
	if stanza.attr.xmlns == nil and origin.send then
		log("debug", "Unhandled %s stanza: %s; xmlns=%s", origin.type, stanza.name, xmlns); -- we didn't handle it
		if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	elseif not((name == "features" or name == "error") and xmlns == "http://etherx.jabber.org/streams") then -- FIXME remove check once we handle S2S features
		log("warn", "Unhandled %s stream element or stanza: %s; xmlns=%s: %s", origin.type, stanza.name, xmlns, tostring(stanza)); -- we didn't handle it
		origin:close("unsupported-stanza-type");
	end
end

local iq_types = { set=true, get=true, result=true, error=true };
function cluster.core_process_stanza(origin, stanza)
	module:log("debug", "--- sipwise_cluster.core_process_staza --");
	--module:log("debug", "--- origin:%s stanza:%s",
	--	ut.table.tostring(origin), tostring(stanza));

	if not ut.string.starts(origin.type, "s2sc") then return core.process_stanza(origin, stanza) end
	(origin.log or log)("debug", "--- Received[%s]: %s", origin.type, stanza:top_tag())
		-- TODO verify validity of stanza (as well as JID validity)
	if stanza.attr.type == "error" and #stanza.tags == 0 then return; end -- TODO invalid stanza, log
	if stanza.name == "iq" then
		if not stanza.attr.id then stanza.attr.id = ""; end -- COMPAT Jabiru doesn't send the id attribute on roster requests
		if not iq_types[stanza.attr.type] or ((stanza.attr.type == "set" or stanza.attr.type == "get") and (#stanza.tags ~= 1)) then
			origin.sends2sc(st.error_reply(stanza, "modify", "bad-request", "Invalid IQ type or incorrect number of children"));
			return;
		end
	end

	if origin.type == "c2scin" and not stanza.attr.xmlns then
		if not origin.full_jid
			and not(stanza.name == "iq" and stanza.attr.type == "set" and stanza.tags[1] and stanza.tags[1].name == "bind"
					and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
			-- authenticated client isn't bound and current stanza is not a bind request
			if stanza.attr.type ~= "result" and stanza.attr.type ~= "error" then
				origin.sends2sc(st.error_reply(stanza, "auth", "not-authorized")); -- FIXME maybe allow stanzas to account or server
			end
			return;
		end

		-- TODO also, stanzas should be returned to their original state before the function ends
		stanza.attr.from = origin.full_jid;
	end
	local to, xmlns = stanza.attr.to, stanza.attr.xmlns;
	local from = stanza.attr.from;
	local node, host, resource;
	local from_node, from_host, from_resource;
	local to_bare, from_bare;
	if to then
		if full_sessions[to] or bare_sessions[to] or hosts[to] then
			node, host = jid_split(to); -- TODO only the host is needed, optimize
		else
			node, host, resource = jid_prepped_split(to);
			if not host then
				log("warn", "Received stanza with invalid destination JID: %s", to);
				if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
					origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The destination address is invalid: "..to));
				end
				return;
			end
			to_bare = node and (node.."@"..host) or host; -- bare JID
			if resource then to = to_bare.."/"..resource; else to = to_bare; end
			stanza.attr.to = to;
		end
	end
	if from and not origin.full_jid then
		-- We only stamp the 'from' on c2s stanzas, so we still need to check validity
		from_node, from_host, from_resource = jid_prepped_split(from);
		if not from_host then
			log("warn", "Received stanza with invalid source JID: %s", from);
			if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
				origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The source address is invalid: "..from));
			end
			return;
		end
		from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
		if from_resource then from = from_bare.."/"..from_resource; else from = from_bare; end
		stanza.attr.from = from;
	end

	if (origin.type == "s2scin") and xmlns == nil then
		if origin.type == "s2csin" and not origin.dummy then
			local host_status = origin.hosts[from_host];
			if not host_status or not host_status.authed then -- remote server trying to impersonate some other server?
				log("warn", "Received a stanza claiming to be from %s, over a stream authed for %s!", from_host, origin.from_host);
				origin:close("not-authorized");
				return;
			elseif not hosts[host] then
				log("warn", "Remote server %s sent us a stanza for %s, closing stream", origin.from_host, host);
				origin:close("host-unknown");
				return;
			end
		end
		cluster.core_post_stanza(origin, stanza, origin.full_jid);
	else
		local h = hosts[stanza.attr.to or origin.host or origin.to_host];
		if h then
			local event;
			if xmlns == nil then
				if stanza.name == "iq" and (stanza.attr.type == "set" or stanza.attr.type == "get") then
					event = "stanza/iq/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name;
				else
					event = "stanza/"..stanza.name;
				end
			else
				event = "stanza/"..xmlns..":"..stanza.name;
			end
			module:log("debug", "--- event:%s stanza:%s", event, tostring(stanza));
			if h.events.fire_event(event, {origin = origin, stanza = stanza}) then return; end
		end
		if host and not hosts[host] then host = nil; end -- COMPAT: workaround for a Pidgin bug which sets 'to' to the SRV result
		handle_unhandled_stanza(host or origin.host or origin.to_host, origin, stanza);
	end
end

function cluster.core_route_stanza(origin, stanza)
	module:log("debug", "--- sipwise_cluster.core_route_staza --");
	--module:log("debug", "--- origin:%s stanza:%s",
	--	ut.table.tostring(origin), tostring(stanza));
	if not ut.string.starts(origin.type, "s2sc") then return core.route_stanza(origin, stanza) end
	module:log("debug", "---------------- send error ---");
	--origin.sends2sc(st.error_reply(stanza, "cancel", "service-unavailable"));
end

function cluster.core_post_stanza(origin, stanza, preevents)
	module:log("debug", "--- sipwise_cluster.core_post_staza --");
	--module:log("debug", "--- origin:%s stanza:%s",
	--	ut.table.tostring(origin), tostring(stanza));
	if not ut.string.starts(origin.type, "s2sc") then return core.post_stanza(origin, stanza) end
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID

	local to_type, to_self;
	if node then
		if resource then
			to_type = '/full';
		else
			to_type = '/bare';
			if node == origin.username and host == origin.host then
				stanza.attr.to = nil;
				to_self = true;
			end
		end
	else
		if host then
			to_type = '/host';
		else
			to_type = '/bare';
			to_self = true;
		end
	end

	local event_data = {origin=origin, stanza=stanza};
	if preevents then -- c2s connection
		module:log("debug", "fire event:%s stanza:%s", 'pre-'..stanza.name..to_type, tostring(stanza));
		if hosts[origin.host].events.fire_event('pre-'..stanza.name..to_type, event_data) then return; end -- do preprocessing
	end
	local h = hosts[to_bare] or hosts[host or origin.host];
	if h then
		module:log("debug", "fire event:%s stanza:%s", stanza.name..to_type, tostring(stanza));
		if h.events.fire_event(stanza.name..to_type, event_data) then return; end -- do processing
		module:log("debug", "fire event:%s stanza:%s", stanza.name..'/self', tostring(stanza));
		if to_self and h.events.fire_event(stanza.name..'/self', event_data) then return; end -- do processing
		handle_unhandled_stanza(h.host, origin, stanza);
	else
		cluster.core_route_stanza(origin, stanza);
	end
end

function set_dialback_secret(host)
	local h = core.hosts[host];
	module:log("debug", "[%s] set cluster dialback_secret", host);
	--module:log("debug", "[%s] %s->%s", host, h.dialback_secret,
	--	cluster_config.dialback_secret);
	h.dialback_secret = cluster_config.dialback_secret;
end

function module.load()
	cluster_config = module:get_option("cluster", cluster_config);
	cluster.dialback_secret = cluster_config.dialback_secret;
	-- TODO check cluster_config.hosts is a set and does not have me
	if cluster.dialback_secret then
		module:hook("host-activated", set_dialback_secret, 100);
	end
end

local function route_cluster(origin, stanza, dest)
	local from_node, from_host, from_resource = jid_split(stanza.attr.from);
	local to_node, to_host, to_resource = jid_split(stanza.attr.to);

	-- Auto-detect origin if not specified
	origin = origin or hosts[from_host];
	if not origin then return false; end

	log("debug", "Routing[%s] to remote cluster[%s]...", tostring(from_host), dest);
	local host_session = hosts[from_host] or hosts[to_host];
	if not host_session then
		log("error", "No hosts[from_host] or hosts[to_host] (please report): %s", tostring(stanza));
	else
		local xmlns = stanza.attr.xmlns;
		stanza.attr.xmlns = nil;
		local routed = host_session.events.fire_event("route/remote_cluster", { origin = origin, stanza = stanza, from_host = from_host, to_host = dest });
		stanza.attr.xmlns = xmlns; -- reset
		if not routed then
			log("debug", "... no, just kidding.");
			if stanza.attr.type == "error" or (stanza.name == "iq" and stanza.attr.type == "result") then return; end
			cluster.core_route_stanza(host_session, st.error_reply(stanza, "cancel", "not-allowed", "Communication with remote domains is not enabled"));
		end
	end
end

local function outbound_handler(event)
	local origin, stanza = event.origin, event.stanza;
	local h, resorces, res;
	local to = stanza.attr.to;
	local stanza_c;

	if origin and ut.string.starts(origin.type, "s2sc") then
		module:log("[outbound] stanza coming from the cluster");
		return
	end
	if to then
		local node, host, resource = jid_split(to);
		if core.hosts[host] then
			module:log("debug", "[outbound] stanza from:%s to:%s",
				tostring(stanza.attr.from), tostring(to));
			--module:log("debug", "--- origin:%s stanza:%s",
			--	ut.table.tostring(origin), tostring(stanza));
			local rhosts = redis_sessions.get_hosts(stanza.attr.to);
			for h,resources in pairs(rhosts) do
				if h and h ~= cluster_config.me then
					for _,res in pairs(resources) do
						stanza_c = st.clone(stanza);
						stanza_c.attr.to = node..'@'..host..'/'..res;
						module:log("debug", "[outbound] send:%s to hosts:%s/%s",
							tostring(stanza_c), h, res);
						route_cluster(origin, stanza_c, h);
					end
				end
			end
		else
			module:log("debug", "[outbound] stanza[%s] not for cluster", host);
		end
	end
end

function module.add_host(module)
	module:log("debug", "cluster hooks host %s!", module.host);
	module:hook("pre-presence/full", outbound_handler, 20);
	module:hook("pre-presence/bare", outbound_handler, 20);
	module:hook("pre-message/full", outbound_handler, 20);
	module:hook("pre-message/bare", outbound_handler, 20);
	module:hook("pre-iq/full", outbound_handler, 20);
	module:hook("pre-iq/bare", outbound_handler, 20);
	-- Stanszas to local clients ??
	module:hook("presence/full", outbound_handler, 20);
	module:hook("presence/bare", outbound_handler, 20);
	module:hook("message/full", outbound_handler, 20);
	module:hook("message/bare", outbound_handler, 20);
	module:hook("iq/full", outbound_handler, 20);
	module:hook("iq/bare", outbound_handler, 20);
end
