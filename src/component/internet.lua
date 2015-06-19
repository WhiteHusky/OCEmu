-- internet component

local okay, socket = pcall(require, "socket")
if not okay then
	cprint("Cannot use internet component: " .. socket)
	return
end
require("support.http_patch")
local url = require("socket.url")
local okay, http = pcall(require, "ssl.https")
if not okay then
	cprint("Cannot use HTTPS: " .. http)
	http = require("socket.http")
end

component.connect("filesystem",gen_uuid(),nil,"lua/component/internet",true)

local obj = {}

local function checkUri(address, port)
	local parsed = url.parse(address)
	if parsed ~= nil and parsed.host ~= nil and (parsed.port ~= nil or port > -1) then
		return parsed.host, parsed.port or port
	end
	local simple = url.parse("oc://" .. address)
	if simple ~= nil and simple.host ~= nil and (simple.port ~= nil or port > -1) then
		return simple.host, simple.port or port
	end
	error("address could not be parsed or no valid port given",4)
end

function obj.isTcpEnabled() -- Returns whether TCP connections can be made (config setting).
	cprint("internet.isTcpEnabled")
	return config.get("internet.enableTcp",true)
end
function obj.isHttpEnabled() -- Returns whether HTTP requests can be made (config setting).
	cprint("internet.isHttpEnabled")
	return config.get("internet.enableHttp",true)
end
function obj.connect(address, port) -- Opens a new TCP connection. Returns the handle of the connection.
	cprint("internet.connect",address, port)
	if port == nil then port = -1 end
	compCheckArg(1,address,"string")
	compCheckArg(2,port,"number")
	if not config.get("internet.enableTcp",true) then
		return nil, "tcp connections are unavailable"
	end
	-- TODO Check for too many connections
	local host, port = checkUri(address, port)
	if host == nil then
		return host, port
	end
	local client = socket.tcp()
	-- TODO: not OC behaviour, but needed to prevent hanging
	client:settimeout(10)
	local connected = false
	local closed = false
	local function connect()
		cprint("(socket) connect",host,port)
		local did, err = client:connect(host,port)
		cprint("(socket) connect results",did,err)
		if did then
			connected = true
			client:settimeout(0)
		else
			pcall(client.close,client)
			closed = true
		end
	end
	local fakesocket = {
		read = function(n)
			cprint("(socket) read",n)
			-- TODO: Better Error handling
			if closed then return nil, "connection lost" end
			if not connected then connect() return "" end
			if type(n) ~= "number" then n = math.huge end
			local data, err, part = client:receive(n)
			if err == nil or err == "timeout" or part ~= "" then
				return data or part
			else
				if err == "closed" then closed = true err = "connection lost" end
				return nil, err
			end
		end,
		write = function(data)
			cprint("(socket) write",data)
			-- TODO: Better Error handling
			if closed then return nil, "connection lost" end
			if not connected then connect() return 0 end
			checkArg(1,data,"string")
			local data, err, part = client:send(data)
			if err == nil or err == "timeout" or part ~= 0 then
				return data or part
			else
				if err == "closed" then closed = true err = "connection lost" end
				return nil, err
			end
		end,
		close = function()
			cprint("(socket) close")
			pcall(client.close,client)
			closed = true
		end,
		finishConnect = function()
			cprint("(socket) finishConnect")
			-- TODO: Does this actually error?
			if closed then return nil, "connection lost" end
			return connected
		end
	}
	return fakesocket
end
function obj.request(url, postData) -- Starts an HTTP request. If this returns true, further results will be pushed using `http_response` signals.
	cprint("internet.request",url, postData)
	compCheckArg(1,url,"string")
	if not config.get("internet.enableHttp",true) then
		return nil, "http requests are unavailable"
	end
	-- TODO: Check for too many connections
	if type(postData) ~= "string" then
		postData = nil
	end
	-- TODO: This works ... but is slow.
	-- TODO: Infact so slow, it can trigger the machine's sethook, so we have to work around that.
	local hookf,hookm,hookc = debug.gethook()
	local co = coroutine.running()
	debug.sethook(co)
	local page, err, headers, status = http.request(url, postData)
	debug.sethook(co,hookf,hookm,hookc)
	if not page then
		cprint("(request) request failed",err)
	end
	-- Experimental fix for headers
	if headers ~= nil then
		local oldheaders = headers
		headers = {}
		for k,v in pairs(oldheaders) do
			local name = k:gsub("^.",string.upper):gsub("%-.",string.upper)
			if type(v) == "table" then
				v.n = #v
				headers[name] = v
			else
				headers[name] = {v,n=1}
			end
		end
	end
	local procotol, code, message
	if status then
		protocol, code, message = status:match("(.-) (.-) (.*)")
		code = tonumber(code)
	end
	local closed = false
	local fakesocket = {
		read = function(n)
			cprint("(socket) read",n)
			-- OC doesn't actually return n bytes when requested.
			if closed then
				return nil, "connection lost"
			elseif headers == nil then
				return nil, "Connection refused"
			elseif page == "" then
				return nil
			else
				-- Return up to 8192 bytes
				local data = page:sub(1,8192)
				page = page:sub(8193)
				return data
			end
		end,
		response = function()
			cprint("(socket) response")
			if headers == nil then
				return nil
			end
			return code, message, headers
		end,
		close = function()
			cprint("(request) close")
			closed = true
			page = nil
		end,
		finishConnect = function()
			cprint("(socket) finishConnect")
			if closed then
				return nil, "connection lost"
			elseif headers == nil then
				return nil, "Connection refused"
			end
			return true
		end
	}
	return fakesocket
end

local cec = {}

local doc = {
	["isTcpEnabled"]="function():boolean -- Returns whether TCP connections can be made (config setting).",
	["isHttpEnabled"]="function():boolean -- Returns whether HTTP requests can be made (config setting).",
	["connect"]="function(address:string[, port:number]):userdata -- Opens a new TCP connection. Returns the handle of the connection.",
	["request"]="function(url:string[, postData:string]):userdata -- Starts an HTTP request. If this returns true, further results will be pushed using `http_response` signals.",
}

return obj,cec,doc
