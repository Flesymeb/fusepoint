class_name FusepointProductShell
extends CanvasLayer

const STATE_TITLE := &"title"
const STATE_LOADOUT := &"loadout"
const STATE_LOADING := &"loading"
const STATE_BRIEFING := &"briefing"
const STATE_GAMEPLAY := &"gameplay"
const STATE_PAUSE := &"pause"
const STATE_SETTINGS := &"settings"
const STATE_DEATH := &"death_recovery"
const STATE_RESULT := &"result"

@onready var root: Control = $Root
@onready var pages: Control = $Root/Pages
@onready var settings_store: FusepointSettingsStore = $SettingsStore
@onready var mission: Node = get_node("../MissionController")
@onready var player: CharacterBody3D = get_node("../PrototypePlayer")
@onready var weapon: Node = get_node("../PrototypePlayer/Head/Camera3D/WeaponController")
@onready var roster: Node = get_node("../EnemyRoster")
@onready var hud: CanvasLayer = get_node("../TacticalHUD")
@onready var terminal: Node = get_node("../TerminalPresentation")

var app_state := STATE_TITLE
var _return_from_settings := STATE_TITLE
var _selected_weapon := &"ak74m"
var _loading_remaining := 0.0
var _transition_serial := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_controls()
	player.player_died.connect(_on_player_died)
	terminal.presentation_completed.connect(_on_terminal_presentation_completed)
	settings_store.settings_applied.connect(_on_settings_applied)
	_set_gameplay_enabled(false)
	_load_settings_controls()
	_show_page(STATE_TITLE)


func _connect_controls() -> void:
	$Root/Pages/TitlePage/Menu/StartButton.pressed.connect(_open_loadout)
	$Root/Pages/TitlePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_TITLE))
	$Root/Pages/TitlePage/Menu/QuitButton.pressed.connect(get_tree().quit)
	$Root/Pages/LoadoutPage/Content/Weapons/AKButton.pressed.connect(_select_weapon.bind(&"ak74m"))
	$Root/Pages/LoadoutPage/Content/Weapons/SaigaButton.pressed.connect(_select_weapon.bind(&"saiga12"))
	$Root/Pages/LoadoutPage/Content/Actions/ConfirmButton.pressed.connect(_start_loading)
	$Root/Pages/LoadoutPage/Content/Actions/BackButton.pressed.connect(_show_page.bind(STATE_TITLE))
	$Root/Pages/BriefingPage/Actions/DeployButton.pressed.connect(_deploy)
	$Root/Pages/BriefingPage/Actions/BackButton.pressed.connect(_show_page.bind(STATE_LOADOUT))
	$Root/Pages/PausePage/Menu/ResumeButton.pressed.connect(_resume_gameplay)
	$Root/Pages/PausePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_PAUSE))
	$Root/Pages/PausePage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/PausePage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/SettingsPage/Actions/ApplyButton.pressed.connect(_apply_settings)
	$Root/Pages/SettingsPage/Actions/CancelButton.pressed.connect(_cancel_settings)
	$Root/Pages/DeathPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/DeathPage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/ResultPage/Menu/ReplayButton.pressed.connect(_replay)
	$Root/Pages/ResultPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/ResultPage/Menu/HomeButton.pressed.connect(_return_home)


func _input(event: InputEvent) -> void:
	if app_state != STATE_GAMEPLAY and event.is_action_pressed(&"menu_accept"):
		var focused := get_viewport().gui_get_focus_owner()
		if focused is BaseButton:
			(focused as BaseButton).pressed.emit()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(&"pause"):
		if app_state == STATE_GAMEPLAY:
			_pause_gameplay()
		elif app_state == STATE_PAUSE:
			_resume_gameplay()
		get_viewport().set_input_as_handled()
		return
	if not (event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"menu_back")):
		return
	match app_state:
		STATE_LOADOUT, STATE_BRIEFING:
			_show_page(STATE_TITLE if app_state == STATE_LOADOUT else STATE_LOADOUT)
		STATE_SETTINGS:
			_cancel_settings()
		STATE_PAUSE:
			_resume_gameplay()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if app_state == STATE_LOADING and _loading_remaining > 0.0:
		_loading_remaining = maxf(_loading_remaining - delta, 0.0)
		$Root/Pages/LoadingPage/Progress.value = (1.0 - _loading_remaining / 1.35) * 100.0
		if _loading_remaining <= 0.0:
			_show_page(STATE_BRIEFING)


func _show_page(state: StringName) -> void:
	_transition_serial += 1
	app_state = state
	pages.visible = state != STATE_GAMEPLAY
	for child in pages.get_children():
		(child as Control).visible = child.name == _page_name(state)
	if state != STATE_GAMEPLAY:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_focus_first_button.call_deferred()


func _page_name(state: StringName) -> String:
	return {
		STATE_TITLE: "TitlePage",
		STATE_LOADOUT: "LoadoutPage",
		STATE_LOADING: "LoadingPage",
		STATE_BRIEFING: "BriefingPage",
		STATE_PAUSE: "PausePage",
		STATE_SETTINGS: "SettingsPage",
		STATE_DEATH: "DeathPage",
		STATE_RESULT: "ResultPage",
	}.get(state, "TitlePage")


func _focus_first_button() -> void:
	var page := pages.get_node_or_null(_page_name(app_state))
	if page == null:
		return
	for control in page.find_children("*", "Button", true, false):
		var button := control as Button
		if button.visible and not button.disabled:
			button.grab_focus()
			return


func _open_loadout() -> void:
	_show_page(STATE_LOADOUT)
	_select_weapon(_selected_weapon)


func _select_weapon(weapon_id: StringName) -> void:
	_selected_weapon = weapon_id
	var ak := $Root/Pages/LoadoutPage/Content/Weapons/AKButton as Button
	var saiga := $Root/Pages/LoadoutPage/Content/Weapons/SaigaButton as Button
	ak.button_pressed = weapon_id == &"ak74m"
	saiga.button_pressed = weapon_id == &"saiga12"
	$Root/Pages/LoadoutPage/Content/Selection.text = "SELECTED  •  %s" % ("AK-74M ASSAULT" if weapon_id == &"ak74m" else "SAIGA-12 BREACH")


func _start_loading() -> void:
	if app_state != STATE_LOADOUT:
		return
	_loading_remaining = 1.35
	$Root/Pages/LoadingPage/Progress.value = 0.0
	_show_page(STATE_LOADING)


func _deploy() -> void:
	if app_state != STATE_BRIEFING:
		return
	if not weapon.call(&"equip_loadout", _selected_weapon):
		$Root/Pages/BriefingPage/Error.text = "LOADOUT UNAVAILABLE — RETURN AND SELECT A VALID WEAPON"
		return
	if not mission.call(&"begin_deployment"):
		$Root/Pages/BriefingPage/Error.text = "DEPLOYMENT ALREADY COMMITTED"
		return
	get_tree().paused = false
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY)


func _set_gameplay_enabled(enabled: bool) -> void:
	player.call(&"set_gameplay_input_enabled", enabled)
	weapon.call(&"set_gameplay_input_enabled", enabled)
	roster.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	hud.call(&"set_hud_enabled", enabled)


func _pause_gameplay() -> void:
	if app_state != STATE_GAMEPLAY:
		return
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	get_tree().paused = true
	_show_page(STATE_PAUSE)


func _resume_gameplay() -> void:
	if app_state != STATE_PAUSE:
		return
	get_tree().paused = false
	player.call(&"set_gameplay_input_enabled", true)
	weapon.call(&"set_gameplay_input_enabled", true)
	_show_page(STATE_GAMEPLAY)


func _open_settings_from(return_state: StringName) -> void:
	_return_from_settings = return_state
	_load_settings_controls()
	_show_page(STATE_SETTINGS)


func _load_settings_controls() -> void:
	var values := settings_store.snapshot()
	$Root/Pages/SettingsPage/Settings/MasterVolume.value = float(values["master_volume"]) * 100.0
	$Root/Pages/SettingsPage/Settings/UIScale.value = float(values["ui_scale"]) * 100.0
	$Root/Pages/SettingsPage/Settings/FOV.value = float(values["fov"])
	$Root/Pages/SettingsPage/Settings/SubtitleSize.value = float(values["subtitle_size"])
	$Root/Pages/SettingsPage/Settings/ReducedMotion.button_pressed = bool(values["reduced_camera_motion"])
	$Root/Pages/SettingsPage/Settings/ScreenShake.button_pressed = bool(values["screen_shake"])
	$Root/Pages/SettingsPage/Settings/HoldADS.button_pressed = bool(values["hold_ads"])


func _apply_settings() -> void:
	settings_store.save_settings({
		"master_volume": $Root/Pages/SettingsPage/Settings/MasterVolume.value / 100.0,
		"ui_scale": $Root/Pages/SettingsPage/Settings/UIScale.value / 100.0,
		"fov": $Root/Pages/SettingsPage/Settings/FOV.value,
		"subtitle_size": $Root/Pages/SettingsPage/Settings/SubtitleSize.value,
		"reduced_camera_motion": $Root/Pages/SettingsPage/Settings/ReducedMotion.button_pressed,
		"screen_shake": $Root/Pages/SettingsPage/Settings/ScreenShake.button_pressed,
		"hold_ads": $Root/Pages/SettingsPage/Settings/HoldADS.button_pressed,
	})
	_cancel_settings()


func _on_settings_applied(values: Dictionary) -> void:
	var subtitle_size := int(values["subtitle_size"])
	var narrative := hud.get_node_or_null("Root/Narrative") as Label
	if narrative != null:
		narrative.add_theme_font_size_override("font_size", subtitle_size)


func _cancel_settings() -> void:
	_show_page(_return_from_settings)


func _on_player_died(_event: Dictionary) -> void:
	if app_state != STATE_GAMEPLAY or StringName(mission.get("mission_state")) != &"active_gameplay":
		return
	get_tree().paused = true
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	_show_page(STATE_DEATH)


func _restart_checkpoint() -> void:
	if app_state == STATE_RESULT:
		return
	mission.call(&"request_checkpoint_restore")
	get_tree().paused = false
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY)


func _return_home() -> void:
	get_tree().paused = false
	terminal.reset_presentation(true, true)
	mission.call(&"reset_for_replay")
	_set_gameplay_enabled(false)
	_show_page(STATE_TITLE)


func _replay() -> void:
	get_tree().paused = false
	terminal.reset_presentation(true, true)
	mission.call(&"reset_for_replay")
	_set_gameplay_enabled(false)
	_show_page(STATE_LOADOUT)


func _on_terminal_presentation_completed(_event_id: String, result: StringName) -> void:
	if app_state == STATE_GAMEPLAY:
		_show_result(result)


func _show_result(result: StringName) -> void:
	_set_gameplay_enabled(false)
	var success := result == &"bomb_defused"
	$Root/Pages/ResultPage/Outcome.text = "MISSION COMPLETE" if success else "MISSION FAILED"
	$Root/Pages/ResultPage/Outcome.modulate = Color(0.2, 0.92, 0.82) if success else Color(1.0, 0.27, 0.18)
	var snapshot: Dictionary = mission.call(&"result_snapshot")
	var components: Dictionary = snapshot.get("score_components", {})
	var remaining := int(snapshot.get("remaining_seconds", 0))
	var completion := int(snapshot.get("completion_seconds", 0))
	var rank := int(snapshot.get("leaderboard_rank", 0))
	var rank_text := "—" if rank <= 0 else "#%d" % rank
	$Root/Pages/ResultPage/Metrics.text = "RESULT  %s    SCORE  %d\nCOMPLETION  %02d:%02d    REMAINING  %02d:%02d\nALPHA  %s    BRAVO  %s\nELIMINATIONS  %d    DEATHS  %d    RESTARTS  %d\n\nSCORE COMPONENTS\nTIME %+d  •  A %+d  •  B %+d  •  ELIMS %+d\nDIAGNOSIS %+d  •  ISOLATION %+d  •  DETONATOR %+d\nDEATHS %+d  •  RESTARTS %+d\n\nFASTEST-SUCCESS DELTA  %+.1fs    LEADERBOARD  %s" % [
		String(result).replace("_", " ").to_upper(), int(snapshot.get("score", 0)),
		completion / 60, completion % 60, remaining / 60, remaining % 60,
		"SECURED" if snapshot.get("alpha_captured", false) else "HOSTILE",
		"SECURED" if snapshot.get("bravo_captured", false) else "HOSTILE",
		int(snapshot.get("eliminations", 0)), int(snapshot.get("deaths", 0)), int(snapshot.get("restart_count", 0)),
		int(components.get("time", 0)), int(components.get("alpha", 0)), int(components.get("bravo", 0)), int(components.get("eliminations", 0)),
		int(components.get("diagnosis", 0)), int(components.get("power_isolation", 0)), int(components.get("detonator_removal", 0)),
		int(components.get("deaths", 0)), int(components.get("checkpoint_restarts", 0)),
		float(snapshot.get("fastest_success_delta", 0.0)), rank_text,
	]
	$Root/Pages/ResultPage/Menu/RestartButton.visible = not success and remaining > 0 and int(mission.get("checkpoint_version")) > 0
	_show_page(STATE_RESULT)


func _mcp_state() -> Dictionary:
	return {
		"app_state": app_state,
		"pages_visible": pages.visible,
		"selected_weapon": _selected_weapon,
		"transition_serial": _transition_serial,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled"),
		"mission_state": mission.get("mission_state"),
		"terminal_presentation": terminal.snapshot(),
		"focused_control": str(get_viewport().gui_get_focus_owner().get_path()) if get_viewport().gui_get_focus_owner() != null else "",
	}
