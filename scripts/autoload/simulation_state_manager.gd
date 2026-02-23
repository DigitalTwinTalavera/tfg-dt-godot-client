## SimulationStateManager autoload singleton
## Tracks the current simulation state machine ("idle", "running", "paused", "stopped")
## and exposes convenience helpers used by the UI and other systems.
extends Node


## Emitted whenever the simulation state changes
signal state_changed(new_state: String, old_state: String)

## Emitted specifically when simulation starts running
signal simulation_started()

## Emitted specifically when simulation is paused
signal simulation_paused()

## Emitted specifically when simulation is stopped or goes idle
signal simulation_stopped()


## Known backend state values
const STATE_IDLE: String = "idle"
const STATE_RUNNING: String = "running"
const STATE_PAUSED: String = "paused"
const STATE_STOPPED: String = "stopped"
const STATE_UNKNOWN: String = "unknown"


## Current simulation state (read-only externally)
var current_state: String = STATE_UNKNOWN

## Simulation time received from the last tick (seconds)
var simulation_time: float = 0.0

## Last known tick index
var last_tick: int = 0


func _ready() -> void:
	SimulationClient.sim_state_received.connect(_on_sim_state)
	SimulationClient.tick_received.connect(_on_tick)
	SimulationClient.connected.connect(_on_ws_connected)
	SimulationClient.disconnected.connect(_on_ws_disconnected)
	_log_info("Initialized")


## Convenience helpers -----------------------------------------------------

func is_running() -> bool:
	return current_state == STATE_RUNNING


func is_paused() -> bool:
	return current_state == STATE_PAUSED


func is_stopped() -> bool:
	return current_state == STATE_STOPPED or current_state == STATE_IDLE


func is_active() -> bool:
	return current_state == STATE_RUNNING or current_state == STATE_PAUSED


## Handlers ----------------------------------------------------------------

func _on_sim_state(new_state: String) -> void:
	if new_state == current_state:
		return

	var old := current_state
	current_state = new_state

	_log_info("State: %s → %s" % [old, new_state])
	state_changed.emit(new_state, old)

	match new_state:
		STATE_RUNNING:
			simulation_started.emit()
		STATE_PAUSED:
			simulation_paused.emit()
		STATE_STOPPED, STATE_IDLE:
			simulation_stopped.emit()


func _on_tick(tick: int, sim_time: float, _vehicles: Array) -> void:
	last_tick = tick
	simulation_time = sim_time


func _on_ws_connected() -> void:
	current_state = STATE_UNKNOWN
	simulation_time = 0.0
	last_tick = 0
	_log_info("Reset — waiting for sim_state message")


func _on_ws_disconnected() -> void:
	current_state = STATE_UNKNOWN
	_log_info("Connection lost — state unknown")


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[SimulationStateManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[SimulationStateManager] %s" % message)
