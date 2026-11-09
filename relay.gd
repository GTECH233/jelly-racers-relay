extends SceneTree
## Jelly Racers online relay server.
##
## Players connect over WebSocket (works from browsers too). The host asks for
## a room and gets a 5-letter code; friends join with that code. After that the
## server just forwards each game packet to the right players in the room.
##
## Run:  godot --headless --path server -s relay.gd -- --port=24600
## (the PORT environment variable also works, which most hosting services set)
##
## Messages (first byte = type, ints are 32-bit little endian):
##   client -> server   1 HOST  version           2 JOIN  id, code|version
##                      4 DATA  target, payload    (target 0 = everyone, <0 = everyone but -target)
##   server -> client   1 HOSTED code             2 JOINED (after the PEER_ADDs)
##                      3 PEER_ADD id             5 PEER_DEL id
##                      4 DATA from, payload      6 CLOSED (host left)    7 ERROR text

const HOST := 1
const JOIN := 2
const PEER_ADD := 3
const DATA := 4
const PEER_DEL := 5
const CLOSED := 6
const ERROR := 7
const MAX_PLAYERS := 8
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var _server := TCPServer.new()
var _clients := {}      # client key -> {ws, room, id, t}
var _rooms := {}        # code -> {version, members: {id: client key}}
var _next_key := 1
var _stat_t := 0.0


func _init() -> void:
	var port := 24600
	if OS.has_environment("PORT"):
		port = OS.get_environment("PORT").to_int()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = a.get_slice("=", 1).to_int()
	if _server.listen(port) != OK:
		printerr("Relay: couldn't listen on port %d" % port)
		quit(1)
		return
	print("Jelly Racers relay listening on port %d" % port)


func _process(delta: float) -> bool:
	while _server.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1 << 20
		ws.outbound_buffer_size = 1 << 20
		ws.max_queued_packets = 4096
		ws.heartbeat_interval = 15.0
		ws.accept_stream(_server.take_connection())
		_clients[_next_key] = {"ws": ws, "room": "", "id": 0, "t": Time.get_ticks_msec()}
		_next_key += 1
	for key in _clients.keys():
		var c: Dictionary = _clients[key]
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				_handle(key, ws.get_packet())
		elif st == WebSocketPeer.STATE_CLOSED:
			_drop(key)
		elif st == WebSocketPeer.STATE_CONNECTING and Time.get_ticks_msec() - int(c["t"]) > 15000:
			_drop(key)
	_stat_t -= delta
	if _stat_t <= 0.0:
		_stat_t = 60.0
		print("relay: %d connections, %d rooms" % [_clients.size(), _rooms.size()])
	return false


func _send(key: int, type: int, body: PackedByteArray = PackedByteArray()) -> void:
	if not _clients.has(key):
		return
	var out := PackedByteArray([type])
	out.append_array(body)
	(_clients[key]["ws"] as WebSocketPeer).send(out)


func _int(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return b


func _error(key: int, text: String) -> void:
	_send(key, ERROR, text.to_utf8_buffer())


func _new_code() -> String:
	while true:
		var code := ""
		for i in 5:
			code += CODE_CHARS[randi() % CODE_CHARS.length()]
		if not _rooms.has(code):
			return code
	return ""


func _handle(key: int, pkt: PackedByteArray) -> void:
	if pkt.is_empty():
		return
	var c: Dictionary = _clients[key]
	match pkt[0]:
		HOST:
			if c["room"] != "":
				return
			var code := _new_code()
			_rooms[code] = {"version": pkt.slice(1).get_string_from_utf8(), "members": {1: key}}
			c["room"] = code
			c["id"] = 1
			_send(key, HOST, code.to_utf8_buffer())
			print("room %s opened" % code)
		JOIN:
			if c["room"] != "" or pkt.size() < 5:
				return
			var id := pkt.decode_s32(1)
			var parts := pkt.slice(5).get_string_from_utf8().split("|")
			var code := parts[0].strip_edges().to_upper()
			var version := parts[1] if parts.size() > 1 else ""
			if not _rooms.has(code):
				_error(key, "No game with code %s. Check the code and try again." % code)
				return
			var room: Dictionary = _rooms[code]
			var members: Dictionary = room["members"]
			if String(room["version"]) != version:
				_error(key, "That game is on a different version (%s). Both players need the same version." % room["version"])
				return
			if members.size() >= MAX_PLAYERS:
				_error(key, "That game is full.")
				return
			if id <= 1 or members.has(id):
				_error(key, "Couldn't join, please try again.")
				return
			# tell the newcomer who's here, then everyone about the newcomer
			for other_id in members:
				_send(key, PEER_ADD, _int(other_id))
				_send(members[other_id], PEER_ADD, _int(id))
			members[id] = key
			c["room"] = code
			c["id"] = id
			_send(key, JOIN)
		DATA:
			if c["room"] == "" or pkt.size() < 5 or not _rooms.has(c["room"]):
				return
			var target := pkt.decode_s32(1)
			var body := _int(int(c["id"]))
			body.append_array(pkt.slice(5))
			var members: Dictionary = _rooms[c["room"]]["members"]
			if target > 0:
				if members.has(target):
					_send(members[target], DATA, body)
			else:
				for other_id in members:
					if other_id != c["id"] and other_id != -target:
						_send(members[other_id], DATA, body)


func _drop(key: int) -> void:
	var c: Dictionary = _clients[key]
	_clients.erase(key)
	var code: String = c["room"]
	if code == "" or not _rooms.has(code):
		return
	var members: Dictionary = _rooms[code]["members"]
	members.erase(c["id"])
	if int(c["id"]) == 1:
		# host left: the room closes
		for other_id in members:
			_send(members[other_id], CLOSED)
		_rooms.erase(code)
		print("room %s closed" % code)
	else:
		for other_id in members:
			_send(members[other_id], PEER_DEL, _int(int(c["id"])))
