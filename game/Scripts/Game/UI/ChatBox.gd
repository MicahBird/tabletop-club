# tabletop-club
# Copyright (c) 2020-2022 Benjamin 'drwhut' Beddows.
# Copyright (c) 2021-2022 Tabletop Club contributors (see game/CREDITS.tres).
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

extends HBoxContainer

enum {
	FONT_SMALL,
	FONT_MEDIUM,
	FONT_LARGE
}

onready var _chat_container = $VBoxContainer
onready var _chat_text = $VBoxContainer/ChatBackground/ChatText
onready var _message_edit = $VBoxContainer/HBoxContainer/MessageEdit
onready var _toggle_button = $ToggleButton

export(int) var font_size: int = FONT_LARGE setget set_font_size

const NUM_CHARS_BEFORE_TIMEOUT: int = 1000
const TIMEOUT_WAIT_TIME: float = 1.0

var _num_chars_recent: int = 0
var _time_since_last_msg: float = 0.0

# Add a message in BBCode format to the chat box.
# raw_message: The message to add in BBCode format.
# stdout: If true, also prints the message to the stdout buffer.
func add_raw_message(raw_message: String, stdout: bool = true) -> void:
	if _time_since_last_msg > TIMEOUT_WAIT_TIME:
		if _num_chars_recent >= NUM_CHARS_BEFORE_TIMEOUT:
			_chat_text.clear() # Clear tag stack.
		_num_chars_recent = 0
	
	if _num_chars_recent < NUM_CHARS_BEFORE_TIMEOUT:
		_num_chars_recent += raw_message.length()
		if _num_chars_recent >= NUM_CHARS_BEFORE_TIMEOUT:
			_chat_text.add_text("\n[%s]" % tr("Too much text being sent, waiting..."))
		else:
			_chat_text.bbcode_text += "\n" + raw_message
			_time_since_last_msg = 0.0
			
			# Print an unformatted version of the message to stdout.
			if stdout:
				print(_chat_text.text.rsplit("\n", true, 1)[1])

# Apply options from the options menu.
# config: The options to apply.
func apply_options(config: ConfigFile) -> void:
	set_font_size(config.get_value("multiplayer", "chat_font_size"))

# Clear all text from the chat box.
func clear_all() -> void:
	_chat_text.clear()

# Clear all instances of a given BBCode tag from the chat box.
# tag: The tag to clear - if it contains an '=' character, it will be assumed
# the ending tag will be everything before the '='.
func clear_tag(tag: String) -> void:
	var end_tag = "/" + tag.split("=", true, 1)[0]
	
	var old_text = _chat_text.bbcode_text
	var text_length = old_text.length()
	var start_length = tag.length() + 2
	var end_length = end_tag.length() + 2
	
	var new_text = ""
	var start_add_from = 0
	var currently_in_tag = false
	for i in range(text_length):
		if currently_in_tag:
			if i < text_length:
				var end_check = old_text.substr(i - end_length + 1, end_length)
				if end_check == "[%s]" % end_tag:
					currently_in_tag = false
					start_add_from = i + 1
		else:
			if i <= text_length - start_length:
				var start_check = old_text.substr(i, start_length)
				if start_check == "[%s]" % tag:
					currently_in_tag = true
					# We assume the tag has a newline before it.
					new_text += old_text.substr(start_add_from, i - start_add_from - 1)
	
	if not currently_in_tag:
		new_text += old_text.substr(start_add_from)
	_chat_text.bbcode_text = new_text

# Check if the chat box is visible.
# Returns: If the chat box is visible.
func is_chat_visible() -> bool:
	return _chat_container.visible

# Send a message to the server if there is valid text in the text box.
func prepare_send_message() -> void:
	var message = _message_edit.text.strip_edges()
	if message.length() > 0:
		rpc_id(1, "send_message", message)
	
	_message_edit.clear()

# Called by the server to say a message was sent by someone.
remotesync func receive_message(sender_id: int, message: String) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	# Security!
	message = message.strip_edges().strip_escapes().replace("[", "[ ")
	if message.length() == 0:
		return
	
	message = Lobby.get_name_bb_code(sender_id) + ": " + message
	
	if Global.censoring_profanity:
		message = Global.censor_profanity(message)
	
	add_raw_message(message)

# Send a message to the server.
# message: The message to send.
master func send_message(message: String) -> void:
	rpc("receive_message", get_tree().get_rpc_sender_id(), message)

# Set the chat box to be visible.
# chat_visible: Whether the chat box should be visible or not.
func set_chat_visible(chat_visible: bool) -> void:
	_chat_container.visible = chat_visible
	
	var text = ">"
	if chat_visible:
		text = "<"
	_toggle_button.text = text

# Set the size of the font in the text window.
# size: The size of the font, e.g. FONT_MEDIUM.
func set_font_size(size: int) -> void:
	if size < FONT_SMALL or size > FONT_LARGE:
		push_error("Font size (%d) is invalid!" % size)
		return
	
	if size != font_size:
		var normal_font: DynamicFont = null
		var bold_font: DynamicFont   = null
		var italic_font: DynamicFont = null
		
		match size:
			FONT_SMALL:
				normal_font = preload("res://Fonts/Cabin/Modified/ChatBox/Cabin-Regular-Small.tres")
				bold_font   = preload("res://Fonts/Cabin/Modified/ChatBox/Cabin-Bold-Small.tres")
				italic_font = preload("res://Fonts/Cabin/Modified/ChatBox/Cabin-Italic-Small.tres")
			FONT_MEDIUM:
				normal_font = preload("res://Fonts/Cabin/Modified/ChatBox/Cabin-Regular-Medium.tres")
				bold_font   = preload("res://Fonts/Cabin/Modified/ChatBox/Cabin-Bold-Medium.tres")
				italic_font = preload("res://Fonts/Cabin/Modified/ChatBox/Cabin-Italic-Medium.tres")
			FONT_LARGE:
				normal_font = preload("res://Fonts/Cabin/Cabin-Regular.tres")
				bold_font   = preload("res://Fonts/Cabin/Cabin-Bold.tres")
				italic_font = preload("res://Fonts/Cabin/Cabin-Italic.tres")
		
		_chat_text.add_font_override("normal_font", normal_font)
		_chat_text.add_font_override("bold_font", bold_font)
		_chat_text.add_font_override("italics_font", italic_font)
		
		font_size = size

func _ready():
	set_chat_visible(true)
	
	Global.connect("censor_changed", self, "_on_Global_censor_changed")

func _process(delta):
	_time_since_last_msg += delta

# Get a random string from an array.
# Returns: A random line from the given array.
# text_file: The array to get the line from.
func _random_string_from_array(array: Array) -> String:
	if array.empty():
		return ""
	
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var line = array[rng.randi() % array.size()]
	
	return line

func _on_Global_censor_changed():
	if Global.censoring_profanity:
		_chat_text.bbcode_text = Global.censor_profanity(_chat_text.bbcode_text)

func _on_MessageEdit_text_entered(_new_text: String):
	prepare_send_message()

func _on_SendButton_pressed():
	prepare_send_message()

func _on_ToggleButton_pressed():
	set_chat_visible(not is_chat_visible())
