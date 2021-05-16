# tabletop-club
# Copyright (c) 2020-2021 Benjamin 'drwhut' Beddows
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# NOTE: The WebRTC code in this script is based on the webrtc_signalling demo,
# which is licensed under the MIT license:
# https://github.com/godotengine/godot-demo-projects/blob/master/networking/webrtc_signaling/client/multiplayer_client.gd

extends Node

onready var _connecting_dialog = $ConnectingDialog
onready var _master_server = $MasterServer
onready var _room = $Room
onready var _table_state_error_dialog = $TableStateErrorDialog
onready var _table_state_version_dialog = $TableStateVersionDialog
onready var _ui = $GameUI

var _rtc = WebRTCMultiplayer.new()
var _established_connection_with = []

var _player_name: String
var _player_color: Color

var _room_state_saving: Dictionary = {}
var _state_version_save: Dictionary = {}

# Apply options from the options menu.
# config: The options to apply.
func apply_options(config: ConfigFile) -> void:
	_room.apply_options(config)
	_ui.apply_options(config)
	
	_player_name = config.get_value("multiplayer", "name")
	_player_color = config.get_value("multiplayer", "color")
	
	if not get_tree().is_network_server():
		if not _connecting_dialog.visible:
			Lobby.rpc_id(1, "request_modify_self", _player_name, _player_color)

# Ask the master server to host a game.
func start_host() -> void:
	_connect_to_master_server("")

# Ask the master server to join a game.
func start_join(room_code: String) -> void:
	_connect_to_master_server(room_code)

# Start the game in singleplayer mode.
func start_singleplayer() -> void:
	# Pretend that we asked the master server to host our own game.
	call_deferred("_on_connected", 1)
	
	_ui.hide_chat_box()

# Stop the connections to the other peers and the master server.
func stop() -> void:
	_rtc.close()
	_master_server.close()

func _ready():
	_master_server.connect("connected", self, "_on_connected")
	_master_server.connect("disconnected", self, "_on_disconnected")
	
	_master_server.connect("offer_received", self, "_on_offer_received")
	_master_server.connect("answer_received", self, "_on_answer_received")
	_master_server.connect("candidate_received", self, "_on_candidate_received")
	
	_master_server.connect("room_joined", self, "_on_room_joined")
	_master_server.connect("room_sealed", self, "_on_room_sealed")
	_master_server.connect("peer_connected", self, "_on_peer_connected")
	_master_server.connect("peer_disconnected", self, "_on_peer_disconnected")
	
	Lobby.connect("players_synced", self, "_on_Lobby_players_synced")
	
	Lobby.clear_players()

func _process(_delta):
	var current_peers = _rtc.get_peers()
	for id in current_peers:
		var peer: Dictionary = current_peers[id]
		
		if peer["connected"]:
			if not id in _established_connection_with:
				_on_connection_established(id)
				_established_connection_with.append(id)

func _unhandled_input(event):
	if event.is_action_pressed("game_take_screenshot"):
		# Create the user://screenshots folder if it doesn't already exist.
		var screenshot_dir = Directory.new()
		if screenshot_dir.open("user://") != OK:
			push_error("Cannot open user:// directory!")
			return
		
		if not screenshot_dir.dir_exists("screenshots"):
			if screenshot_dir.make_dir("screenshots") != OK:
				push_error("Failed to create the user://screenshots directory!")
				return
		
		if screenshot_dir.change_dir("screenshots") != OK:
			push_error("Failed to change to the user://screenshots directory!")
			return
		
		var dt = OS.get_datetime()
		var name = "%d-%d-%d-%d-%d-%d.png" % [dt["year"], dt["month"],
			dt["day"], dt["hour"], dt["minute"], dt["second"]]
		var path = screenshot_dir.get_current_dir() + "/" + name
		
		var image = get_viewport().get_texture().get_data()
		image.flip_y()
		if image.save_png(path) == OK:
			var message = "Saved screenshot to '%s'." % path
			print(message)
			
			# TODO: Show a notification in the UI with this message.
		else:
			push_error("Failed to save screenshot to '%s'!" % path)
			return

# Connect to the master server, and ask to join the given room.
# room_code: The room code to join with. If empty, ask the master server to
# make our own room.
func _connect_to_master_server(room_code: String = "") -> void:
	stop()
	
	_connecting_dialog.popup_centered()
	
	_master_server.room_code = room_code
	_master_server.connect_to_url("ws://localhost:9080")

# Create a network peer object.
# Returns: A WebRTCPeerConnection for the given peer.
# id: The ID of the peer.
func _create_peer(id: int) -> WebRTCPeerConnection:
	var peer = WebRTCPeerConnection.new()
	peer.initialize({
		"iceServers": [
			{ "urls": ["stun:stun.l.google.com:19302"] }
		]
	})
	
	peer.connect("session_description_created", self, "_on_offer_created", [id])
	peer.connect("ice_candidate_created", self, "_on_new_ice_candidate", [id])
	
	_rtc.add_peer(peer, id)
	if id > _rtc.get_unique_id():
		peer.create_offer()
	
	return peer

# Open a table state (.tc) file in the given mode.
# Returns: A file object for the given path, null if it failed to open.
# path: The file path to open.
# mode: The mode to open the file with.
func _open_table_state_file(path: String, mode: int) -> File:
	var file = File.new()
	var open_err = file.open_compressed(path, mode, File.COMPRESSION_ZSTD)
	if open_err == OK:
		return file
	else:
		_popup_table_state_error(tr("Could not open the file at path '%s' (error %d).") % [path, open_err])
		return null

# Show the table state popup dialog with the given error.
# error: The error message to show.
func _popup_table_state_error(error: String) -> void:
	_table_state_error_dialog.dialog_text = error
	_table_state_error_dialog.popup_centered()
	
	push_error(error)

# Show the table state version popup with the given message.
# message: The message to show.
func _popup_table_state_version(message: String) -> void:
	_table_state_version_dialog.dialog_text = message
	_table_state_version_dialog.popup_centered()
	
	push_warning(message)

func _on_connected(id: int):
	print("Connected %d" % id)
	_rtc.initialize(id, true)
	
	# Assign the WebRTCMultiplayer object to the scene tree, so all nodes can
	# use it with the RPC system.
	get_tree().network_peer = _rtc
	
	_connecting_dialog.visible = false
	
	# If we are the host, then add ourselves to the lobby, and create our own
	# hand.
	if id == 1:
		Lobby.rpc_id(1, "add_self", 1, _player_name, _player_color)
		
		var hand_transform = _room.srv_get_next_hand_transform()
		if hand_transform == Transform.IDENTITY:
			push_warning("Table has no available hand positions!")
		_room.rpc_id(1, "add_hand", 1, hand_transform)

func _on_disconnected():
	stop()
	
	print("Failed to connect to the server!")
	Global.start_main_menu_with_error(tr("Failed to connect to the server! Code: %d Reason: %s") % [_master_server.code, _master_server.reason])

func _on_answer_received(id: int, answer: String):
	print("Got answer: %d" % id)
	if _rtc.has_peer(id):
		_rtc.get_peer(id).connection.set_remote_description("answer", answer)

func _on_candidate_received(id: int, mid: String, index: int, sdp: String):
	if _rtc.has_peer(id):
		_rtc.get_peer(id).connection.add_ice_candidate(mid, index, sdp)

func _on_connection_established(id: int):
	# If a player has connected to the server, let them know of every piece on
	# the board so far.
	if get_tree().is_network_server():
		_room.rpc_id(id, "set_state", _room.get_state(true, true))
		
		# If there is space, also give them a hand on the table.
		var hand_transform = _room.srv_get_next_hand_transform()
		if hand_transform != Transform.IDENTITY:
			_room.rpc("add_hand", id, hand_transform)
	
	# If we are not the host, then ask the host to send us their list of
	# players.
	elif id == 1:
		Lobby.rpc_id(1, "request_sync_players")
		_room.start_sending_cursor_position()

func _on_new_ice_candidate(mid: String, index: int, sdp: String, id: int):
	_master_server.send_candidate(id, mid, index, sdp)

func _on_offer_created(type: String, data: String, id: int):
	if not _rtc.has_peer(id):
		return
	print("created ", type)
	_rtc.get_peer(id).connection.set_local_description(type, data)
	if type == "offer":
		_master_server.send_offer(id, data)
	else:
		_master_server.send_answer(id, data)

func _on_offer_received(id: int, offer: String):
	print("Got offer %d" % id)
	if _rtc.has_peer(id):
		_rtc.get_peer(id).connection.set_remote_description("offer", offer)

func _on_peer_connected(id: int):
	print("Peer connected %d" % id)
	_create_peer(id)

func _on_peer_disconnected(id: int):
	if _rtc.has_peer(id):
		_rtc.remove_peer(id)
	
	if id in _established_connection_with:
		_established_connection_with.erase(id)
	
	if get_tree().is_network_server():
		Lobby.rpc("remove_self", id)
		
		_room.rpc("remove_hand", id)
		_room.srv_stop_player_hovering(id)

func _on_room_joined(room_code: String):
	_master_server.room_code = room_code

func _on_room_sealed():
	pass

func _on_GameUI_about_to_save_table():
	_room_state_saving = _room.get_state(false, false)

func _on_GameUI_applying_options(config: ConfigFile):
	apply_options(config)

func _on_GameUI_flipping_table(reset_table: bool):
	if reset_table:
		_room.rpc_id(1, "request_unflip_table")
	else:
		_room.rpc_id(1, "request_flip_table", _room.get_camera_transform().basis)

func _on_GameUI_lighting_requested(lamp_color: Color, lamp_intensity: float,
	lamp_sunlight: bool):
	
	_room.rpc_id(1, "request_set_lamp_color", lamp_color)
	_room.rpc_id(1, "request_set_lamp_intensity", lamp_intensity)
	_room.rpc_id(1, "request_set_lamp_type", lamp_sunlight)

func _on_GameUI_load_table(path: String):
	var file = _open_table_state_file(path, File.READ)
	if file:
		var state = file.get_var()
		file.close()
		
		if state is Dictionary:
			var our_version = ProjectSettings.get_setting("application/config/version")
			if state.has("version") and state["version"] == our_version:
				_room.rpc_id(1, "request_load_table_state", state)
			else:
				_state_version_save = state
				if not state.has("version"):
					_popup_table_state_version(tr("Loaded table has no version information. Load anyway?"))
				else:
					_popup_table_state_version(tr("Loaded table was saved with a different version of the game (Current: %s, Table: %s). Load anyway?") % [our_version, state["version"]])
		else:
			_popup_table_state_error(tr("Loaded table is not in the correct format."))

func _on_GameUI_piece_requested(piece_entry: Dictionary, position: Vector3):
	_room.rpc_id(1, "request_add_piece", piece_entry, position)

func _on_GameUI_piece_requested_in_container(piece_entry: Dictionary, container_name: String):
	_room.rpc_id(1, "request_add_piece_in_container", piece_entry, container_name)

func _on_GameUI_requesting_room_details():
	_ui.set_room_details(_room.get_table(), _room.get_skybox(),
		_room.get_lamp_color(), _room.get_lamp_intensity(),
		_room.get_lamp_type())

func _on_GameUI_save_table(path: String):
	if _room_state_saving.empty():
		push_error("Room state to save is empty!")
		return
	
	var file = _open_table_state_file(path, File.WRITE)
	if file:
		file.store_var(_room_state_saving)
		file.close()

func _on_GameUI_stopped_saving_table():
	_room_state_saving = {}

func _on_GameUI_skybox_requested(skybox_entry: Dictionary):
	_room.rpc_id(1, "request_set_skybox", skybox_entry)

func _on_GameUI_table_requested(table_entry: Dictionary):
	_room.rpc_id(1, "request_set_table", table_entry)

func _on_Lobby_players_synced():
	if not get_tree().is_network_server():
		Lobby.rpc_id(1, "request_add_self", _player_name, _player_color)

func _on_Room_setting_spawn_point(position: Vector3):
	_ui.spawn_point_origin = position

func _on_Room_spawning_piece_at(position: Vector3):
	_ui.spawn_point_container_name = ""
	_ui.spawn_point_temp_offset = position - _ui.spawn_point_origin
	_ui.popup_objects_dialog()

func _on_Room_spawning_piece_in_container(container_name: String):
	_ui.spawn_point_container_name = container_name
	_ui.popup_objects_dialog()

func _on_Room_table_flipped(table_reset: bool):
	_ui.set_flip_table_status(not table_reset)

func _on_TableStateVersionDialog_confirmed():
	_room.rpc_id(1, "request_load_table_state", _state_version_save)
