## UI Logger utility for RichTextLabel-based logging
## Centralizes logging functions used across test scenes to avoid duplication
class_name UILogger
extends RefCounted


## The RichTextLabel to output logs to
var _log_output: RichTextLabel


## Initialize the logger with a RichTextLabel output
func _init(log_output: RichTextLabel) -> void:
	_log_output = log_output


## Log an info message (default color)
func info(message: String) -> void:
	if _log_output:
		_log_output.append_text(message + "\n")


## Log a success message (green)
func success(message: String) -> void:
	if _log_output:
		_log_output.append_text("[color=green]%s[/color]\n" % message)


## Log an error message (red)
func error(message: String) -> void:
	if _log_output:
		_log_output.append_text("[color=red]%s[/color]\n" % message)


## Log a warning message (yellow)
func warning(message: String) -> void:
	if _log_output:
		_log_output.append_text("[color=yellow]%s[/color]\n" % message)


## Log a debug message (gray) - only shown in debug mode
func debug(message: String) -> void:
	if _log_output and Config.DEBUG_MODE:
		_log_output.append_text("[color=gray]%s[/color]\n" % message)


## Clear the log output
func clear() -> void:
	if _log_output:
		_log_output.clear()


## Add a separator line
func separator(sep_char: String = "-", length: int = 40) -> void:
	info(sep_char.repeat(length))


## Log with a custom color
func colored(message: String, color: String) -> void:
	if _log_output:
		_log_output.append_text("[color=%s]%s[/color]\n" % [color, message])
