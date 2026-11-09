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
const REDEEM := 8          # client -> server: code (a pack download key or link)
const REDEEMED := 9        # server -> client: ok(1/0), then pack id or a message
const MAX_PLAYERS := 8
## Store packs are checked with itch.io. Set these on the host (e.g. Render >
## Environment): ITCH_API_KEY = your itch.io API key, and
## PACK_GAMES = neon=1234567,space=2345678,beach=...,volcano=...,farm=...
## (each pack's itch.io game id). The key never leaves the server.
var _itch_key := OS.get_environment("ITCH_API_KEY")
var _pack_games := {}      # pack id -> itch game id
var _tries := {}           # client key -> [count, window start ms]
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
	for pair in OS.get_environment("PACK_GAMES").split(",", false):
		var kv := pair.split("=")
		if kv.size() == 2:
			_pack_games[kv[0].strip_edges()] = kv[1].strip_edges()
	print("store: %d packs configured, api key %s" % [_pack_games.size(), "set" if _itch_key != "" else "MISSING"])
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
		REDEEM:
			_redeem(key, pkt.slice(1).get_string_from_utf8())
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


func _reply_redeem(key: int, ok: bool, text: String) -> void:
	var body := PackedByteArray([1 if ok else 0])
	body.append_array(text.to_utf8_buffer())
	_send(key, REDEEMED, body)


## Checks a pack code with itch.io: is it a real download key for one of the
## pack pages? Accepts the bare key or the whole download link.
func _redeem(key: int, raw: String) -> void:
	var now := Time.get_ticks_msec()
	var t: Array = _tries.get(key, [0, now])
	if now - int(t[1]) > 60000:
		t = [0, now]
	t[0] = int(t[0]) + 1
	_tries[key] = t
	if int(t[0]) > 5:
		_reply_redeem(key, false, "Too many tries. Wait a minute and try again.")
		return
	if _itch_key == "" or _pack_games.is_empty():
		_reply_redeem(key, false, "The Store isn't open yet. Try again soon!")
		return
	var code := raw.strip_edges()
	var at := code.find("/download/")
	if at >= 0:
		code = code.substr(at + 10)
	for sep in ["/", "?", "#", " "]:
		var cut := code.find(sep)
		if cut >= 0:
			code = code.left(cut)
	var re := RegEx.create_from_string("^[A-Za-z0-9]{10,64}$")
	if re.search(code) == null:
		_reply_redeem(key, false, "That doesn't look like a pack code. Paste the download link from your itch.io receipt.")
		return
	for pack_id in _pack_games:
		var http := HTTPRequest.new()
		http.timeout = 15.0
		root.add_child(http)
		var url := "https://itch.io/api/1/%s/game/%s/download_keys?download_key=%s" % [_itch_key, _pack_games[pack_id], code.uri_encode()]
		if http.request(url) != OK:
			http.queue_free()
			continue
		var res: Array = await http.request_completed
		http.queue_free()
		if int(res[1]) == 200:
			var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
			if data is Dictionary and data.has("download_key"):
				print("store: redeemed a %s code" % pack_id)
				_reply_redeem(key, true, pack_id)
				return
	_reply_redeem(key, false, "That code isn't valid for any pack. Check you copied the whole link.")


func _drop(key: int) -> void:
	var c: Dictionary = _clients[key]
	_clients.erase(key)
	_tries.erase(key)
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
