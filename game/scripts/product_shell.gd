class_name FusepointProductShell
extends CanvasLayer

const STATE_TITLE := &"title"
const STATE_LOADOUT := &"loadout"
const STATE_LOADING := &"loading"
const STATE_BRIEFING := &"briefing"
const STATE_DEPLOYMENT := &"deployment"
const STATE_GAMEPLAY := &"gameplay"
const STATE_PAUSE := &"pause"
const STATE_SETTINGS := &"settings"
const STATE_DEATH := &"death_recovery"
const STATE_RECOVERING := &"recovery_transition"
const STATE_VICTORY := &"victory"
const STATE_DETONATION := &"detonation"
const STATE_SUCCESS_RESULT := &"success_result"
const STATE_FAILURE_RESULT := &"failure_result"
const DEATH_LOCK_SECONDS := 3.0
const BRIEFING_CAPTIONS: Array[String] = [
	"11:40 — KESTREL RIDGE MILITARY BASE\nRIFT FRONT SIGNALS CONFIRMED INSIDE THE PERIMETER.",
	"SECTOR C ROCKET MAINTENANCE BAY\nA FIVE-MINUTE DETONATION DEVICE IS ARMED.",
	"RETAKE ALPHA. SECURE BRAVO.\nRECOVER BOTH DEFUSAL KEYS.",
	"BREACH CHARLIE AND DISMANTLE THE DEVICE.\nSUPPORT IS NOT COMING.",
]
const BRIEFING_BEAT_SECONDS := 2.5
const TRANSITION_HISTORY_LIMIT := 32
const TERMINAL_RESULT_RECEIPT_LIMIT := 4
const SAFE_AREA_RATIO := 0.05
const LAYOUT_CONTRACT_ID := &"fusepoint_safe_area_v4_container_reflow"
const NON_PAGE_STATES: Array[StringName] = [STATE_DEPLOYMENT, STATE_GAMEPLAY, STATE_VICTORY, STATE_DETONATION]
const LIFECYCLE_TABLE := {
	&"title": {"predecessors":[&"title",&"loadout",&"briefing",&"settings",&"pause",&"death_recovery",&"success_result",&"failure_result"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/TitlePage/Menu/StartButton"},
	&"loadout": {"predecessors":[&"title",&"briefing",&"success_result",&"failure_result"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/LoadoutPage/Content/Weapons/AKButton"},
	&"loading": {"predecessors":[&"loadout"], "authority":&"shell", "blocking":true, "focus":""},
	&"briefing": {"predecessors":[&"loading"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/BriefingPage/Actions/DeployButton"},
	&"deployment": {"predecessors":[&"briefing"], "authority":&"mission", "blocking":true, "focus":""},
	&"gameplay": {"predecessors":[&"deployment",&"pause",&"recovery_transition"], "authority":&"mission", "blocking":false, "focus":""},
	&"pause": {"predecessors":[&"gameplay",&"settings"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/PausePage/Menu/ResumeButton"},
	&"settings": {"predecessors":[&"title",&"pause"], "authority":&"shell", "blocking":true, "focus":"Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume"},
	&"death_recovery": {"predecessors":[&"gameplay"], "authority":&"player_death", "blocking":true, "focus":"Root/Pages/DeathPage/Menu/RestartButton"},
	&"recovery_transition": {"predecessors":[&"death_recovery",&"pause",&"failure_result"], "authority":&"mission_recovery", "blocking":true, "focus":"Root/Pages/DeathPage/Menu/RestartButton"},
	&"victory": {"predecessors":[&"gameplay"], "authority":&"terminal", "blocking":true, "focus":""},
	&"detonation": {"predecessors":[&"gameplay"], "authority":&"terminal", "blocking":true, "focus":""},
	&"success_result": {"predecessors":[&"victory"], "authority":&"terminal", "blocking":true, "focus":"Root/Pages/ResultPage/Menu/ReplayButton"},
	&"failure_result": {"predecessors":[&"detonation"], "authority":&"terminal", "blocking":true, "focus":"Root/Pages/ResultPage/Menu/ReplayButton"},
}
const LIFECYCLE_ACTIONS := {
	&"replay": {"legal_from":[&"success_result",&"failure_result"], "target":&"loadout"},
	&"checkpoint_restart": {"legal_from":[&"pause",&"death_recovery",&"failure_result"], "target":&"recovery_transition"},
	&"home": {"legal_from":[&"pause",&"death_recovery",&"success_result",&"failure_result"], "target":&"title"},
}

@onready var root: Control = $Root
@onready var pages: Control = $Root/Pages
@onready var settings_store: FusepointSettingsStore = $SettingsStore
@onready var mission: Node = get_node("../MissionController")
@onready var player: CharacterBody3D = get_node("../PrototypePlayer")
@onready var weapon: Node = get_node("../PrototypePlayer/Head/Camera3D/WeaponController")
@onready var roster: Node = get_node("../EnemyRoster")
@onready var hud: CanvasLayer = get_node("../TacticalHUD")
@onready var terminal: Node = get_node("../TerminalPresentation")
@onready var damage_feedback: Node = get_node("../PlayerDamageFeedback")
@onready var briefing_video: VideoStreamPlayer = $Root/Pages/BriefingPage/OpeningVideo
@onready var settings_scroll: ScrollContainer = $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll
@onready var settings_grid: GridContainer = $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings

var app_state := STATE_TITLE
var _return_from_settings := STATE_TITLE
var _selected_weapon := &"ak74m"
var _loading_remaining := 0.0
var _transition_serial := 0
var _briefing_elapsed := 0.0
var _briefing_caption_index := -1
var _briefing_complete := false
var _briefing_skip_count := 0
var _deployment_requested := false
var _applied_ui_scale := 1.0
var _applied_subtitle_size := 18
var _reduced_camera_motion := false
var _screen_shake := true
var _last_input_family := &"keyboard_mouse"
var _focus_by_state: Dictionary = {}
var _last_transition_receipt: Dictionary = {}
var _transition_history: Array[Dictionary] = []
var _last_transition_rejection := &""
var _death_lock_remaining := 0.0
var _active_recovery_epoch := 0
var _lifecycle_action_serial := 0
var _last_lifecycle_action_receipt: Dictionary = {}
var _lifecycle_action_history: Array[Dictionary] = []
var _observed_terminal_results: Dictionary = {}
var _terminal_result_receipts: Array[Dictionary] = []
var _opening_media_status := &"uninitialized"
var _opening_completion_source := &""
var _opening_completion_count := 0
var _activation_serial := 0
var _activation_frame := -1
var _last_activation_receipt: Dictionary = {}
var _settings_focus_history: Array[Dictionary] = []
var _last_settings_focus_receipt: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The shell owns page input only while a blocking page is rendered. Keeping
	# either full-screen parent on STOP can swallow mouse look with hidden pages.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_connect_controls()
	player.player_died.connect(_on_player_died)
	mission.mission_event_committed.connect(_on_mission_event_committed)
	terminal.presentation_completed.connect(_on_terminal_presentation_completed)
	damage_feedback.restore_feedback_completed.connect(_on_restore_feedback_completed)
	settings_store.settings_applied.connect(_on_settings_applied)
	root.resized.connect(_apply_responsive_layout)
	briefing_video.finished.connect(_on_opening_video_finished)
	_set_gameplay_enabled(false)
	_load_settings_controls()
	settings_store.apply_runtime()
	_apply_responsive_layout.call_deferred()
	_show_page(STATE_TITLE)


func _connect_controls() -> void:
	$Root/Pages/TitlePage/Menu/StartButton.pressed.connect(_open_loadout)
	$Root/Pages/TitlePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_TITLE))
	$Root/Pages/TitlePage/Menu/QuitButton.pressed.connect(get_tree().quit)
	$Root/Pages/LoadoutPage/Content/Weapons/AKButton.pressed.connect(_select_weapon.bind(&"ak74m"))
	$Root/Pages/LoadoutPage/Content/Weapons/SaigaButton.pressed.connect(_select_weapon.bind(&"saiga12"))
	$Root/Pages/LoadoutPage/Content/Actions/ConfirmButton.pressed.connect(_start_loading)
	$Root/Pages/LoadoutPage/Content/Actions/BackButton.pressed.connect(_show_page.bind(STATE_TITLE))
	$Root/Pages/BriefingPage/Actions/DeployButton.pressed.connect(_briefing_primary_action)
	$Root/Pages/BriefingPage/Actions/PauseButton.pressed.connect(_toggle_opening_pause)
	$Root/Pages/BriefingPage/Actions/BackButton.pressed.connect(_show_page.bind(STATE_LOADOUT))
	$Root/Pages/PausePage/Menu/ResumeButton.pressed.connect(_resume_gameplay)
	$Root/Pages/PausePage/Menu/SettingsButton.pressed.connect(_open_settings_from.bind(STATE_PAUSE))
	$Root/Pages/PausePage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/PausePage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/SettingsPage/SafeArea/Layout/Actions/ApplyButton.pressed.connect(_apply_settings)
	$Root/Pages/SettingsPage/SafeArea/Layout/Actions/CancelButton.pressed.connect(_cancel_settings)
	$Root/Pages/DeathPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/DeathPage/Menu/HomeButton.pressed.connect(_return_home)
	$Root/Pages/ResultPage/Menu/ReplayButton.pressed.connect(_replay)
	$Root/Pages/ResultPage/Menu/RestartButton.pressed.connect(_restart_checkpoint)
	$Root/Pages/ResultPage/Menu/HomeButton.pressed.connect(_return_home)
	_configure_settings_navigation()


func _settings_controls() -> Array[Control]:
	return [
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake,
		$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS,
		$Root/Pages/SettingsPage/SafeArea/Layout/Actions/ApplyButton,
		$Root/Pages/SettingsPage/SafeArea/Layout/Actions/CancelButton,
	]


func _configure_settings_navigation() -> void:
	var controls := _settings_controls()
	for control: Control in controls:
		control.focus_mode = Control.FOCUS_ALL
		if not control.focus_entered.is_connected(_on_settings_focus_entered.bind(control)):
			control.focus_entered.connect(_on_settings_focus_entered.bind(control))
	var first := controls[0]
	var last_setting := controls[6]
	var apply_button := controls[7]
	var cancel_button := controls[8]
	for index in 7:
		var control := controls[index]
		var above: Control = apply_button if index == 0 else controls[index - 1]
		var below: Control = apply_button if index == 6 else controls[index + 1]
		control.focus_neighbor_top = control.get_path_to(above)
		control.focus_neighbor_bottom = control.get_path_to(below)
	apply_button.focus_neighbor_top = apply_button.get_path_to(last_setting)
	apply_button.focus_neighbor_bottom = apply_button.get_path_to(first)
	apply_button.focus_neighbor_right = apply_button.get_path_to(cancel_button)
	cancel_button.focus_neighbor_top = cancel_button.get_path_to(last_setting)
	cancel_button.focus_neighbor_bottom = cancel_button.get_path_to(first)
	cancel_button.focus_neighbor_left = cancel_button.get_path_to(apply_button)


func _on_settings_focus_entered(control: Control) -> void:
	_finalize_settings_focus_receipt.call_deferred(control)


func _finalize_settings_focus_receipt(control: Control) -> void:
	if app_state != STATE_SETTINGS or not is_instance_valid(control):
		return
	var scroll_rect := settings_scroll.get_global_rect()
	var control_rect := control.get_global_rect()
	_last_settings_focus_receipt = {
		"run_epoch": int(mission.get("run_epoch")),
		"page": STATE_SETTINGS,
		"input_family": _last_input_family,
		"focused_control": control.get_path(),
		"focus_visible_in_scroll": not settings_scroll.is_ancestor_of(control) or scroll_rect.encloses(control_rect),
		"scroll_vertical": settings_scroll.scroll_vertical,
		"scroll_viewport_rect": scroll_rect,
		"control_rect": control_rect,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
		"accepted": true,
	}
	_settings_focus_history.append(_last_settings_focus_receipt.duplicate(true))
	while _settings_focus_history.size() > TRANSITION_HISTORY_LIMIT:
		_settings_focus_history.pop_front()


func _input(event: InputEvent) -> void:
	_observe_input_family(event)
	if pages.visible and app_state != STATE_GAMEPLAY and event.is_action_pressed(&"menu_accept"):
		if _activate_focused_control_once():
			get_viewport().set_input_as_handled()
			return
	if not (event.is_action_pressed(&"pause") or event.is_action_pressed(&"menu_back")):
		return
	match app_state:
		STATE_LOADOUT, STATE_BRIEFING:
			_show_page(STATE_TITLE if app_state == STATE_LOADOUT else STATE_LOADOUT)
		STATE_SETTINGS:
			_cancel_settings()
		STATE_PAUSE:
			_resume_gameplay()
		STATE_GAMEPLAY:
			_pause_gameplay()
	get_viewport().set_input_as_handled()


func _activate_focused_control_once() -> bool:
	var focused := get_viewport().gui_get_focus_owner()
	if not (focused is BaseButton):
		return false
	var button := focused as BaseButton
	if not button.is_visible_in_tree() or button.disabled:
		return false
	var frame := Engine.get_process_frames()
	if frame == _activation_frame:
		return true
	_activation_frame = frame
	_activation_serial += 1
	_last_activation_receipt = {
		"activation_id": "shell-activation-%06d" % _activation_serial,
		"frame": frame,
		"state": app_state,
		"input_family": _last_input_family,
		"focused_control": button.get_path(),
		"enabled": true,
		"emission_count": 1,
	}
	if button.toggle_mode:
		button.button_pressed = not button.button_pressed
	button.pressed.emit()
	return true


func _process(delta: float) -> void:
	if app_state == STATE_LOADING and _loading_remaining > 0.0:
		_loading_remaining = maxf(_loading_remaining - delta, 0.0)
		$Root/Pages/LoadingPage/Progress.value = (1.0 - _loading_remaining / 1.35) * 100.0
		if _loading_remaining <= 0.0:
			_show_page(STATE_BRIEFING)
	elif app_state == STATE_BRIEFING and not _briefing_complete:
		_update_briefing(delta)
	elif app_state == STATE_DEATH and _death_lock_remaining > 0.0:
		_death_lock_remaining = maxf(0.0, _death_lock_remaining - delta)
		var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
		recovery_button.disabled = _death_lock_remaining > 0.0
		recovery_button.text = "RECOVERY READY IN %.1f" % _death_lock_remaining if recovery_button.disabled else _recovery_button_text()
		if not recovery_button.disabled:
			recovery_button.grab_focus()


func _show_page(state: StringName, reason := &"page_change", authority := &"shell") -> bool:
	var previous_state := app_state
	var rule: Dictionary = LIFECYCLE_TABLE.get(state, {})
	if rule.is_empty() or not (previous_state in (rule.get("predecessors", []) as Array)) or StringName(rule.get("authority", &"")) != authority:
		_record_transition_rejection(reason, &"illegal_lifecycle_edge")
		return false
	if previous_state == STATE_BRIEFING and state != STATE_BRIEFING:
		briefing_video.stop()
		briefing_video.visible = false
	var focused_before := get_viewport().gui_get_focus_owner()
	if focused_before != null and previous_state != STATE_GAMEPLAY:
		_focus_by_state[previous_state] = focused_before.get_path()
	_transition_serial += 1
	app_state = state
	pages.visible = state not in NON_PAGE_STATES
	root.visible = pages.visible
	if not pages.visible and focused_before != null:
		focused_before.release_focus()
	for child in pages.get_children():
		(child as Control).visible = child.name == _page_name(state)
	if state == STATE_BRIEFING:
		_start_briefing()
	if state not in [STATE_GAMEPLAY, STATE_DEPLOYMENT, STATE_VICTORY, STATE_DETONATION]:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_focus_first_button.call_deferred()
	_commit_transition(previous_state, state, reason)
	_apply_responsive_layout.call_deferred()
	return true


func _page_name(state: StringName) -> String:
	return {
		STATE_TITLE: "TitlePage",
		STATE_LOADOUT: "LoadoutPage",
		STATE_LOADING: "LoadingPage",
		STATE_BRIEFING: "BriefingPage",
		STATE_PAUSE: "PausePage",
		STATE_SETTINGS: "SettingsPage",
		STATE_DEATH: "DeathPage",
		STATE_RECOVERING: "DeathPage",
		STATE_SUCCESS_RESULT: "ResultPage",
		STATE_FAILURE_RESULT: "ResultPage",
	}.get(state, "TitlePage")


func _focus_first_button() -> void:
	var page := pages.get_node_or_null(_page_name(app_state))
	if page == null:
		return
	var focus_path := String((LIFECYCLE_TABLE.get(app_state, {}) as Dictionary).get("focus", ""))
	if not focus_path.is_empty():
		var prescribed := get_node_or_null(focus_path) as Control
		var prescribed_enabled := not (prescribed is BaseButton) or not (prescribed as BaseButton).disabled
		if prescribed != null and prescribed.visible and prescribed.focus_mode != Control.FOCUS_NONE and prescribed_enabled:
			prescribed.grab_focus()
			_finalize_transition_focus()
			return
	var remembered_path: NodePath = _focus_by_state.get(app_state, NodePath())
	if not remembered_path.is_empty():
		var remembered := get_node_or_null(remembered_path) as Control
		var remembered_enabled := not (remembered is BaseButton) or not (remembered as BaseButton).disabled
		if remembered != null and remembered.visible and remembered.focus_mode != Control.FOCUS_NONE and remembered_enabled:
			remembered.grab_focus()
			_finalize_transition_focus()
			return
	for node: Node in page.find_children("*", "Control", true, false):
		var control := node as Control
		var enabled := not (control is BaseButton) or not (control as BaseButton).disabled
		if control.visible and control.focus_mode != Control.FOCUS_NONE and enabled:
			control.grab_focus()
			_finalize_transition_focus()
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


func _start_briefing() -> void:
	_briefing_elapsed = 0.0
	_briefing_caption_index = -1
	_briefing_complete = false
	_deployment_requested = false
	_opening_completion_source = &""
	_opening_completion_count = 0
	$Root/Pages/BriefingPage/Error.text = ""
	var deploy_button := $Root/Pages/BriefingPage/Actions/DeployButton as Button
	var pause_button := $Root/Pages/BriefingPage/Actions/PauseButton as Button
	deploy_button.text = "SKIP BRIEFING  ▶"
	deploy_button.disabled = false
	pause_button.text = "Ⅱ  PAUSE"
	pause_button.disabled = briefing_video.stream == null
	if briefing_video.stream != null:
		_opening_media_status = &"playing"
		briefing_video.visible = true
		briefing_video.paused = false
		briefing_video.play()
	else:
		_opening_media_status = &"matched_still_fallback"
		briefing_video.visible = false
	_update_briefing(0.0)


func _update_briefing(delta: float) -> void:
	if briefing_video.stream != null and briefing_video.paused:
		return
	_briefing_elapsed += maxf(delta, 0.0)
	var next_index := mini(int(_briefing_elapsed / BRIEFING_BEAT_SECONDS), BRIEFING_CAPTIONS.size() - 1)
	if next_index != _briefing_caption_index:
		_briefing_caption_index = next_index
		$Root/Pages/BriefingPage/Copy.text = BRIEFING_CAPTIONS[next_index]
	if _briefing_elapsed >= BRIEFING_BEAT_SECONDS * BRIEFING_CAPTIONS.size():
		_complete_briefing(false)


func _briefing_primary_action() -> void:
	if app_state != STATE_BRIEFING:
		return
	if not _briefing_complete:
		_complete_briefing(true)
		return
	_deploy()


func _toggle_opening_pause() -> void:
	if app_state != STATE_BRIEFING or _briefing_complete or briefing_video.stream == null:
		return
	briefing_video.paused = not briefing_video.paused
	_opening_media_status = &"paused" if briefing_video.paused else &"playing"
	($Root/Pages/BriefingPage/Actions/PauseButton as Button).text = "▶  RESUME" if briefing_video.paused else "Ⅱ  PAUSE"


func _complete_briefing(skipped: bool) -> void:
	if _briefing_complete:
		return
	_briefing_complete = true
	_opening_completion_count += 1
	_opening_completion_source = &"skip" if skipped else &"video_finished" if _opening_media_status == &"finished" else &"timed_caption_complete"
	if briefing_video.is_playing():
		briefing_video.stop()
	($Root/Pages/BriefingPage/Actions/PauseButton as Button).disabled = true
	if skipped:
		_briefing_skip_count += 1
		_opening_media_status = &"skipped"
	elif _opening_media_status != &"matched_still_fallback":
		_opening_media_status = &"completed"
	$Root/Pages/BriefingPage/Copy.text = "MISSION PACKAGE SYNCHRONIZED\nAUTHORIZE DEPLOYMENT WHEN READY."
	$Root/Pages/BriefingPage/Actions/DeployButton.text = "AUTHORIZE DEPLOYMENT  ▶"


func _on_opening_video_finished() -> void:
	if app_state != STATE_BRIEFING or _briefing_complete:
		return
	_opening_media_status = &"finished"
	_complete_briefing(false)


func _deploy() -> void:
	if app_state != STATE_BRIEFING or not _briefing_complete or _deployment_requested:
		return
	_deployment_requested = true
	if not weapon.call(&"equip_loadout", _selected_weapon):
		_deployment_requested = false
		$Root/Pages/BriefingPage/Error.text = "LOADOUT UNAVAILABLE — RETURN AND SELECT A VALID WEAPON"
		return
	if not mission.call(&"begin_deployment"):
		_deployment_requested = false
		$Root/Pages/BriefingPage/Error.text = "DEPLOYMENT ALREADY COMMITTED"
		return
	get_tree().paused = false
	if not _show_page(STATE_DEPLOYMENT, &"deployment_committed", &"mission"):
		return
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY, &"deployment_handoff", &"mission")


func _set_gameplay_enabled(enabled: bool) -> void:
	player.call(&"set_gameplay_input_enabled", enabled)
	weapon.call(&"set_gameplay_input_enabled", enabled)
	roster.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	hud.call(&"set_hud_enabled", enabled)


func _pause_gameplay() -> void:
	if app_state != STATE_GAMEPLAY:
		return
	$Root/Pages/PausePage/Menu/RestartButton.visible = not (mission.get("deployment_snapshot") as Dictionary).is_empty() or int(mission.get("checkpoint_version")) > 0
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.call(&"reset_transient_feedback")
	get_tree().paused = true
	_show_page(STATE_PAUSE)


func _resume_gameplay() -> void:
	if app_state != STATE_PAUSE:
		return
	get_tree().paused = false
	player.call(&"set_gameplay_input_enabled", true)
	weapon.call(&"set_gameplay_input_enabled", true)
	_show_page(STATE_GAMEPLAY, &"resume", &"mission")


func _open_settings_from(return_state: StringName) -> void:
	_return_from_settings = return_state
	_load_settings_controls()
	settings_scroll.scroll_vertical = 0
	_show_page(STATE_SETTINGS)


func _load_settings_controls() -> void:
	var values := settings_store.snapshot()
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume.value = float(values["master_volume"]) * 100.0
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale.value = float(values["ui_scale"]) * 100.0
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV.value = float(values["fov"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize.value = float(values["subtitle_size"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion.button_pressed = bool(values["reduced_camera_motion"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake.button_pressed = bool(values["screen_shake"])
	$Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS.button_pressed = bool(values["hold_ads"])


func _apply_settings() -> void:
	settings_store.save_settings({
		"master_volume": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/MasterVolume.value / 100.0,
		"ui_scale": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/UIScale.value / 100.0,
		"fov": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/FOV.value,
		"subtitle_size": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/SubtitleSize.value,
		"reduced_camera_motion": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ReducedMotion.button_pressed,
		"screen_shake": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/ScreenShake.button_pressed,
		"hold_ads": $Root/Pages/SettingsPage/SafeArea/Layout/SettingsScroll/Settings/HoldADS.button_pressed,
	})
	_cancel_settings()


func _on_settings_applied(values: Dictionary) -> void:
	apply_accessibility_settings(values)


func apply_accessibility_settings(values: Dictionary) -> void:
	_applied_ui_scale = clampf(float(values.get("ui_scale", 1.0)), 1.0, 2.0)
	_applied_subtitle_size = clampi(int(values.get("subtitle_size", 18)), 14, 32)
	_reduced_camera_motion = values.get("reduced_camera_motion", false) == true
	_screen_shake = values.get("screen_shake", true) == true
	$Root/Pages/BriefingPage/Copy.add_theme_font_size_override("font_size", _applied_subtitle_size)
	_apply_readability_scale(root, _applied_ui_scale)
	_apply_responsive_layout.call_deferred()
	if hud.has_method(&"apply_accessibility_settings"):
		hud.call(&"apply_accessibility_settings", values)


func _apply_readability_scale(scope: Node, requested_scale: float) -> void:
	var multiplier := 1.0 + (requested_scale - 1.0) * 0.38
	for node: Node in scope.find_children("*", "Control", true, false):
		var control := node as Control
		if not (control is Label or control is Button or control is CheckButton):
			continue
		if not control.has_meta(&"fusepoint_base_font_size"):
			control.set_meta(&"fusepoint_base_font_size", control.get_theme_font_size("font_size"))
		var base_size := int(control.get_meta(&"fusepoint_base_font_size"))
		if base_size <= 0 or base_size >= 42:
			continue
		control.add_theme_font_size_override("font_size", maxi(base_size, int(round(base_size * multiplier))))


func _set_rect(control_path: NodePath, rect: Rect2) -> void:
	var control := get_node_or_null(control_path) as Control
	if control == null:
		return
	control.position = rect.position
	control.size = rect.size


func _apply_responsive_layout() -> void:
	var viewport := root.size
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return
	var margin := Vector2(maxf(viewport.x * SAFE_AREA_RATIO, 32.0), maxf(viewport.y * SAFE_AREA_RATIO, 24.0))
	var safe := Rect2(margin, viewport - margin * 2.0)
	var expanded := _applied_ui_scale > 1.5
	_set_rect(^"Root/Pages/TitlePage/Accent", Rect2(safe.position, Vector2(4.0, safe.size.y - 28.0)))
	_set_rect(^"Root/Pages/TitlePage/Brand", Rect2(safe.position + Vector2(28.0, 24.0), Vector2(560.0, 212.0)))
	_set_rect(^"Root/Pages/TitlePage/Menu", Rect2(safe.position + Vector2(24.0, 292.0), Vector2(430.0, 238.0)))
	_set_rect(^"Root/Pages/TitlePage/Status", Rect2(safe.position + Vector2(28.0, safe.size.y - 64.0), Vector2(560.0, 58.0)))
	_set_rect(^"Root/Pages/LoadoutPage/Header", Rect2(safe.position + Vector2(0.0, 4.0), Vector2(safe.size.x, 62.0)))
	_set_rect(^"Root/Pages/LoadoutPage/Content", Rect2(safe.position + Vector2(0.0, 82.0), Vector2(620.0, safe.size.y - 88.0)))
	_set_rect(^"Root/Pages/LoadoutPage/RoutePlate", Rect2(Vector2(safe.end.x - 448.0, safe.position.y + 82.0), Vector2(448.0, safe.size.y - 88.0)))
	_set_rect(^"Root/Pages/LoadingPage/Title", Rect2(Vector2(safe.position.x, safe.end.y - 198.0), Vector2(840.0, 60.0)))
	_set_rect(^"Root/Pages/LoadingPage/Detail", Rect2(Vector2(safe.position.x, safe.end.y - 130.0), Vector2(930.0, 64.0)))
	_set_rect(^"Root/Pages/LoadingPage/Progress", Rect2(Vector2(safe.position.x, safe.end.y - 34.0), Vector2(safe.size.x * 0.82, 8.0)))
	# The opening media is the briefing surface, not a card inside it. Keep copy
	# and controls on the safe-area grid while the retained VideoStreamPlayer
	# fills the complete viewport behind those native caption layers.
	_set_rect(^"Root/Pages/BriefingPage/OpeningVideo", Rect2(Vector2.ZERO, viewport))
	_set_rect(^"Root/Pages/BriefingPage/Title", Rect2(safe.position, Vector2(safe.size.x, 58.0)))
	_set_rect(^"Root/Pages/BriefingPage/Copy", Rect2(Vector2(safe.position.x + 12.0, safe.end.y - 194.0), Vector2(safe.size.x - 24.0, 86.0 if expanded else 98.0)))
	_set_rect(^"Root/Pages/BriefingPage/Actions", Rect2(Vector2(safe.position.x, safe.end.y - 92.0), Vector2(660.0, 64.0)))
	_set_rect(^"Root/Pages/BriefingPage/Error", Rect2(Vector2(safe.position.x + 684.0, safe.end.y - 82.0), Vector2(safe.size.x - 684.0, 44.0)))
	_set_rect(^"Root/Pages/PausePage/Title", Rect2(safe.position + Vector2(16.0, 54.0), Vector2(560.0, 72.0)))
	_set_rect(^"Root/Pages/PausePage/Menu", Rect2(safe.position + Vector2(16.0, 164.0), Vector2(420.0, 330.0)))
	_set_rect(^"Root/Pages/DeathPage/Title", Rect2(safe.position + Vector2(16.0, 108.0), Vector2(safe.size.x - 32.0, 86.0)))
	_set_rect(^"Root/Pages/DeathPage/Copy", Rect2(safe.position + Vector2(16.0, 222.0), Vector2(safe.size.x - 32.0, 100.0)))
	_set_rect(^"Root/Pages/DeathPage/Menu", Rect2(Vector2(safe.position.x + 16.0, safe.end.y - 120.0), Vector2(720.0, 72.0)))
	_set_rect(^"Root/Pages/ResultPage/Outcome", Rect2(safe.position + Vector2(16.0, 28.0), Vector2(safe.size.x - 32.0, 74.0)))
	_set_rect(^"Root/Pages/ResultPage/Metrics", Rect2(safe.position + Vector2(16.0, 118.0), Vector2(safe.size.x - 32.0, safe.size.y - 244.0)))
	_set_rect(^"Root/Pages/ResultPage/Menu", Rect2(Vector2(safe.position.x + 16.0, safe.end.y - 94.0), Vector2(820.0, 70.0)))


func _cancel_settings() -> void:
	_show_page(_return_from_settings)


func _on_player_died(_event: Dictionary) -> void:
	if app_state != STATE_GAMEPLAY or StringName(mission.get("mission_state")) != &"active_gameplay":
		return
	get_tree().paused = true
	player.call(&"enter_combat_death_lock")
	player.call(&"set_gameplay_input_enabled", false)
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.call(&"reset_transient_feedback")
	_death_lock_remaining = DEATH_LOCK_SECONDS
	var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
	recovery_button.visible = true
	recovery_button.disabled = true
	recovery_button.text = "RECOVERY READY IN %.1f" % DEATH_LOCK_SECONDS
	$Root/Pages/DeathPage/Copy.text = "Mission clock is locked during recovery.\n%s" % (
		"Restore the latest secured checkpoint without gaining time." if int(mission.get("checkpoint_version")) > 0
		else "Return to the deployment entry without gaining time."
	)
	_show_page(STATE_DEATH, &"ordinary_death", &"player_death")


func _restart_checkpoint() -> void:
	if app_state == STATE_DEATH and _death_lock_remaining > 0.0:
		_record_transition_rejection(&"mission_recovery", &"death_lock_active")
		return
	if not _commit_lifecycle_action(&"checkpoint_restart"):
		return
	if mission.call(&"request_recovery") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"mission_recovery_rejected"
		if not _lifecycle_action_history.is_empty():
			_lifecycle_action_history[-1] = _last_lifecycle_action_receipt.duplicate(true)
		_record_transition_rejection(&"checkpoint_restart", &"checkpoint_unavailable_or_illegal")
		return
	var receipt: Dictionary = mission.get("last_checkpoint_restore_receipt")
	_active_recovery_epoch = int(receipt.get("restore_epoch", 0))
	get_tree().paused = false
	_set_gameplay_enabled(false)
	var recovery_button := $Root/Pages/DeathPage/Menu/RestartButton as Button
	recovery_button.disabled = true
	recovery_button.text = "RESTORING MISSION STATE"
	_show_page(STATE_RECOVERING, &"recovery_receipt_committed", &"mission_recovery")


func _recovery_button_text() -> String:
	return "RECOVER DEPLOYMENT" if int(mission.get("checkpoint_version")) == 0 else "RESTART CHECKPOINT"


func _on_restore_feedback_completed(epoch: int) -> void:
	if app_state != STATE_RECOVERING or epoch != _active_recovery_epoch:
		return
	if mission.call(&"complete_recovery_handoff", epoch) != true:
		_record_transition_rejection(&"recovery_handoff", &"restore_receipt_invalid")
		return
	_active_recovery_epoch = 0
	get_tree().paused = false
	_set_gameplay_enabled(true)
	_show_page(STATE_GAMEPLAY, &"recovery_handoff", &"mission")


func _commit_lifecycle_action(action: StringName) -> bool:
	var rule: Dictionary = LIFECYCLE_ACTIONS.get(action, {})
	if rule.is_empty() or not (app_state in (rule.get("legal_from", []) as Array)):
		_record_transition_rejection(action, &"illegal_lifecycle_action")
		return false
	_lifecycle_action_serial += 1
	_last_lifecycle_action_receipt = {
		"action_id": "run-%06d:shell-action-%06d" % [int(mission.get("run_epoch")), _lifecycle_action_serial],
		"run_epoch": int(mission.get("run_epoch")),
		"action": action,
		"source_state": app_state,
		"target_state": rule.get("target", &""),
		"authoritative_mission_state": mission.get("mission_state"),
		"recovery_epoch": int(mission.get("enemy_restore_epoch")),
		"terminal_event_id": String(mission.get("terminal_event_id")),
		"accepted": true,
	}
	_lifecycle_action_history.append(_last_lifecycle_action_receipt.duplicate(true))
	while _lifecycle_action_history.size() > TRANSITION_HISTORY_LIMIT:
		_lifecycle_action_history.pop_front()
	return true


func _observe_input_family(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_last_input_family = &"gamepad"
	elif event is InputEventKey or event is InputEventMouse:
		_last_input_family = &"keyboard_mouse"


func _commit_transition(previous_state: StringName, next_state: StringName, reason: StringName) -> void:
	_last_transition_rejection = &""
	_last_transition_receipt = {
		"transition_id": "shell-transition-%06d" % _transition_serial,
		"sequence": _transition_serial,
		"previous_state": previous_state,
		"next_state": next_state,
		"reason": reason,
		"accepted": true,
		"rejection_reason": &"",
		"input_family": _last_input_family,
		"focused_control": "",
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
		"lifecycle_authority": (LIFECYCLE_TABLE.get(next_state, {}) as Dictionary).get("authority", &"unknown"),
		"blocking": (LIFECYCLE_TABLE.get(next_state, {}) as Dictionary).get("blocking", true),
		"focus_target": (LIFECYCLE_TABLE.get(next_state, {}) as Dictionary).get("focus", ""),
	}
	_transition_history.append(_last_transition_receipt.duplicate(true))
	while _transition_history.size() > TRANSITION_HISTORY_LIMIT:
		_transition_history.pop_front()


func _finalize_transition_focus() -> void:
	var focused := get_viewport().gui_get_focus_owner()
	var focused_path := str(focused.get_path()) if focused != null else ""
	_last_transition_receipt["focused_control"] = focused_path
	if not _transition_history.is_empty():
		_transition_history[-1]["focused_control"] = focused_path


func _record_transition_rejection(action: StringName, reason: StringName) -> void:
	_transition_serial += 1
	_last_transition_rejection = reason
	var focused := get_viewport().gui_get_focus_owner()
	_last_transition_receipt = {
		"transition_id": "shell-transition-%06d" % _transition_serial,
		"sequence": _transition_serial,
		"previous_state": app_state,
		"next_state": app_state,
		"reason": action,
		"accepted": false,
		"rejection_reason": reason,
		"input_family": _last_input_family,
		"focused_control": str(focused.get_path()) if focused != null else "",
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled") == true,
		"ui_scale": _applied_ui_scale,
	}
	_transition_history.append(_last_transition_receipt.duplicate(true))
	while _transition_history.size() > TRANSITION_HISTORY_LIMIT:
		_transition_history.pop_front()


func _layout_snapshot() -> Dictionary:
	var viewport_size := root.size
	var safe_margin := viewport_size * SAFE_AREA_RATIO
	var safe_rect := Rect2(safe_margin, viewport_size - safe_margin * 2.0)
	var violations: Array[String] = []
	var settings_reflow := {}
	if app_state != STATE_GAMEPLAY:
		var page := pages.get_node_or_null(_page_name(app_state))
		if page != null:
			for child: Node in page.find_children("*", "Control", true, false):
				var control := child as Control
				if not control.is_visible_in_tree() or not (control is Label or control is BaseButton or control is Range):
					continue
				# Scroll content outside the viewport is intentionally reachable, not
				# clipped product UI. The ScrollContainer and focused reveal are the
				# safe-area acceptance boundary for Settings descendants.
				if app_state == STATE_SETTINGS and (control == settings_grid or settings_grid.is_ancestor_of(control)):
					continue
				var rect := control.get_global_rect()
				if not safe_rect.encloses(rect):
					violations.append(str(control.get_path()))
	if app_state == STATE_SETTINGS:
		var critical_controls := _settings_controls()
		var focus_owner := get_viewport().gui_get_focus_owner() as Control
		var scroll_rect := settings_scroll.get_global_rect()
		var focused_in_scroll := focus_owner != null and settings_scroll.is_ancestor_of(focus_owner)
		var focused_revealed := focus_owner != null and (not focused_in_scroll or scroll_rect.encloses(focus_owner.get_global_rect()))
		var inaccessible: Array[String] = []
		for control: Control in critical_controls:
			if control.focus_mode == Control.FOCUS_NONE or not control.is_visible_in_tree():
				inaccessible.append(str(control.get_path()))
		settings_reflow = {
			"mode": &"focus_following_bounded_scroll",
			"follow_focus": settings_scroll.follow_focus,
			"scroll_vertical": settings_scroll.scroll_vertical,
			"scroll_viewport_rect": scroll_rect,
			"content_minimum_size": settings_grid.get_combined_minimum_size(),
			"scroll_required": settings_grid.get_combined_minimum_size().y > settings_scroll.size.y,
			"critical_control_count": critical_controls.size(),
			"inaccessible_controls": inaccessible,
			"focused_control": str(focus_owner.get_path()) if focus_owner != null else "",
			"focused_revealed": focused_revealed,
			"predecessor": _return_from_settings,
			"all_critical_reachable": inaccessible.is_empty(),
		}
		if not settings_scroll.follow_focus or not focused_revealed or not inaccessible.is_empty():
			violations.append("settings_focus_reflow")
	return {
		"contract_id": LAYOUT_CONTRACT_ID,
		"applied_ui_scale": _applied_ui_scale,
		"viewport_size": viewport_size,
		"safe_margin": safe_margin,
		"safe_rect": safe_rect,
		"critical_control_count": 0 if app_state == STATE_GAMEPLAY else (pages.get_node(_page_name(app_state)) as Control).find_children("*", "Control", true, false).size(),
		"violation_count": violations.size(),
		"violations": violations,
		"within_safe_area": violations.is_empty(),
		"settings_reflow": settings_reflow,
		"blocking_shell_visible": root.visible and pages.visible,
		"route_plate_visible": $Root/Pages/LoadoutPage/RoutePlate.is_visible_in_tree(),
		"gameplay_surface_clear": app_state != STATE_GAMEPLAY or (not root.visible and not pages.visible),
	}


func _return_home() -> void:
	if not _commit_lifecycle_action(&"home"):
		return
	get_tree().paused = false
	roster.call(&"reset_transient_feedback")
	terminal.reset_presentation(true, true)
	if mission.call(&"reset_for_replay") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"replay_reset_rejected"
		_record_transition_rejection(&"home", &"replay_reset_rejected")
		return
	_observed_terminal_results.clear()
	_set_gameplay_enabled(false)
	_show_page(STATE_TITLE)


func _replay() -> void:
	if not _commit_lifecycle_action(&"replay"):
		return
	get_tree().paused = false
	roster.call(&"reset_transient_feedback")
	terminal.reset_presentation(true, true)
	if mission.call(&"reset_for_replay") != true:
		_last_lifecycle_action_receipt["accepted"] = false
		_last_lifecycle_action_receipt["failure_reason"] = &"replay_reset_rejected"
		_record_transition_rejection(&"replay", &"replay_reset_rejected")
		return
	_observed_terminal_results.clear()
	_set_gameplay_enabled(false)
	_show_page(STATE_LOADOUT)


func _on_mission_event_committed(event: Dictionary) -> void:
	if StringName(event.get("kind", &"")) != &"terminal_submitted":
		return
	var payload: Dictionary = event.get("payload", {})
	var result := StringName(payload.get("result", &"bomb_detonated"))
	_set_gameplay_enabled(false)
	_show_page(STATE_VICTORY if result == &"bomb_defused" else STATE_DETONATION, &"terminal_submitted", &"terminal")


func _on_terminal_presentation_completed(event_id: String, result: StringName) -> void:
	if _observed_terminal_results.has(event_id):
		return
	if (result == &"bomb_defused" and app_state != STATE_VICTORY) or (result == &"bomb_detonated" and app_state != STATE_DETONATION):
		_record_transition_rejection(&"terminal_completion", &"terminal_predecessor_mismatch")
		return
	_observed_terminal_results[event_id] = result
	var receipt := {
		"run_epoch": int(mission.get("run_epoch")),
		"terminal_event_id": event_id,
		"result": result,
		"presentation_completion_usec": Time.get_ticks_usec(),
		"presentation_completion_frame": Engine.get_process_frames(),
		"predecessor_state": app_state,
		"terminal_commit_count": int(mission.get("terminal_commit_count")),
		"duplicate_submit_count": int(mission.get("terminal_duplicate_submit_count")),
		"result_payload": mission.call(&"result_snapshot"),
	}
	_show_result(result)
	receipt["result_state"] = app_state
	receipt["transition_receipt"] = _last_transition_receipt.duplicate(true)
	receipt["actions"] = [&"replay", &"home"]
	_terminal_result_receipts.append(receipt)
	while _terminal_result_receipts.size() > TERMINAL_RESULT_RECEIPT_LIMIT:
		_terminal_result_receipts.pop_front()


func _show_result(result: StringName) -> void:
	_set_gameplay_enabled(false)
	roster.call(&"reset_transient_feedback")
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
	$Root/Pages/ResultPage/Menu/RestartButton.visible = not success and remaining > 0 and (not (mission.get("deployment_snapshot") as Dictionary).is_empty() or int(mission.get("checkpoint_version")) > 0)
	_show_page(STATE_SUCCESS_RESULT if success else STATE_FAILURE_RESULT, &"terminal_presentation_completed", &"terminal")


func _mcp_state() -> Dictionary:
	return {
		"run_epoch": int(mission.get("run_epoch")),
		"app_state": app_state,
		"pages_visible": pages.visible,
		"shell_root_visible": root.visible,
		"route_plate_visible": $Root/Pages/LoadoutPage/RoutePlate.is_visible_in_tree(),
		"gameplay_surface_clear": app_state != STATE_GAMEPLAY or (not root.visible and not pages.visible),
		"selected_weapon": _selected_weapon,
		"focused_control": str(get_viewport().gui_get_focus_owner().get_path()) if get_viewport().gui_get_focus_owner() != null else "",
		"applied_ui_scale": _applied_ui_scale,
		"paused": get_tree().paused,
		"gameplay_input_enabled": player.get("gameplay_input_enabled"),
		"last_input_family": _last_input_family,
		"last_settings_focus_receipt": _last_settings_focus_receipt,
		"layout": _layout_snapshot(),
		"transition_serial": _transition_serial,
		"last_transition_receipt": _last_transition_receipt,
		"transition_history": _transition_history,
		"lifecycle_table_state_count": LIFECYCLE_TABLE.size(),
		"lifecycle_action_count": LIFECYCLE_ACTIONS.size(),
		"last_lifecycle_action_receipt": _last_lifecycle_action_receipt,
		"lifecycle_action_history": _lifecycle_action_history,
		"last_transition_rejection": _last_transition_rejection,
		"activation_serial": _activation_serial,
		"last_activation_receipt": _last_activation_receipt,
		"settings_focus_history": _settings_focus_history,
		"briefing_elapsed": _briefing_elapsed,
		"briefing_caption_index": _briefing_caption_index,
		"briefing_caption_line_count": ($Root/Pages/BriefingPage/Copy as Label).text.count("\n") + 1,
		"briefing_complete": _briefing_complete,
		"briefing_skip_count": _briefing_skip_count,
		"opening_media_status": _opening_media_status,
		"opening_stream_bound": briefing_video.stream != null,
		"opening_video_playing": briefing_video.is_playing(),
		"opening_completion_source": _opening_completion_source,
		"opening_completion_count": _opening_completion_count,
		"opening_video_path": "res://assets/cinematics/fusepoint_opening.ogv",
		"opening_receipt_path": "res://art/source/cinematics/opening_fusepoint_daylight_i2v/generation_receipt.json",
		"deployment_requested": _deployment_requested,
		"death_lock_remaining": _death_lock_remaining,
		"active_recovery_epoch": _active_recovery_epoch,
		"recovery_source": (mission.get("last_checkpoint_restore_receipt") as Dictionary).get("recovery_source", &"none"),
		"applied_subtitle_size": _applied_subtitle_size,
		"reduced_camera_motion": _reduced_camera_motion,
		"screen_shake": _screen_shake,
		"mission_state": mission.get("mission_state"),
		"terminal_event_id": String(mission.get("terminal_event_id")),
		"result_entry_count": _observed_terminal_results.size(),
		"observed_terminal_results": _observed_terminal_results.duplicate(true),
		"terminal_result_receipts": _terminal_result_receipts.duplicate(true),
		"terminal_result_receipt_count": _terminal_result_receipts.size(),
		"terminal_presentation": terminal.snapshot(),
	}
