class_name Player
extends CharacterBody3D
## Spelarkontroller: FPS-kamera, flytande rörelse, hopp och dash.
## Kräver nodträd: Player > Head (Node3D) > Camera3D

# ---------- Signaler (HUD m.fl. kan lyssna på dessa) ----------
signal dashed
## Skickas varje frame med hur redo dashen är (0.0 = laddar, 1.0 = redo)
signal dash_charge_changed(ratio: float)

# ---------- Inställningar (justeras i Inspector) ----------
@export_group("Rörelse")
@export var max_speed: float = 8.0
@export var ground_acceleration: float = 60.0   # Hur snabbt vi når full fart på marken
@export var ground_friction: float = 50.0       # Hur snabbt vi stannar på marken
@export var air_acceleration: float = 20.0      # Kontroll i luften
@export var air_friction: float = 4.0           # Liten bromsning i luften (bevarar momentum)

@export_group("Hopp")
@export var jump_velocity: float = 6.0
@export var gravity_multiplier: float = 1.6     # Högre = "tyngre" och snabbare hopp
@export var coyote_time: float = 0.12           # Får hoppa en kort stund efter att ha lämnat kanten
@export var jump_buffer_time: float = 0.12      # Hopptryck strax innan landning räknas ändå
@export var jump_cut_factor: float = 0.5        # Släpper du hopp tidigt blir hoppet lägre

@export_group("Dash")
@export var dash_speed: float = 24.0
@export var dash_duration: float = 0.18
@export var dash_cooldown: float = 1.0
@export var dash_fov_boost: float = 14.0        # Extra FOV under dash (fartkänsla)

@export_group("Kamera")
@export var mouse_sensitivity: float = 0.0025
@export var max_pitch_degrees: float = 89.0
@export var base_fov: float = 75.0
@export var fov_lerp_speed: float = 10.0

# ---------- Noder ----------
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

# ---------- Interna variabler ----------
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _coyote_left: float = 0.0
var _jump_buffer_left: float = 0.0
var _dash_time_left: float = 0.0
var _dash_cooldown_left: float = 0.0
var _dash_direction: Vector3 = Vector3.ZERO


# =====================================================================
# LIVSCYKEL
# =====================================================================
func _ready() -> void:
	_setup_input_actions()
	camera.fov = base_fov
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	# Titta runt med musen
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_handle_mouse_look(event.relative)

	# Esc växlar mellan fångad/fri mus (praktiskt vid utveckling)
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	_update_timers(delta)
	_apply_gravity(delta)

	var wish_dir: Vector3 = _get_wish_direction()

	_handle_jump()
	_handle_dash_input(wish_dir)

	if _is_dashing():
		_apply_dash_velocity()
	else:
		_apply_horizontal_movement(wish_dir, delta)

	move_and_slide()
	_update_camera_fov(delta)


# =====================================================================
# KAMERA
# =====================================================================
func _handle_mouse_look(relative: Vector2) -> void:
	# Horisontellt: rotera hela spelaren. Vertikalt: rotera bara huvudet.
	rotate_y(-relative.x * mouse_sensitivity)
	head.rotate_x(-relative.y * mouse_sensitivity)
	head.rotation.x = clampf(
		head.rotation.x,
		deg_to_rad(-max_pitch_degrees),
		deg_to_rad(max_pitch_degrees)
	)


func _update_camera_fov(delta: float) -> void:
	# Mjuk FOV-övergång: breddare vid dash ger en tydlig fartkänsla
	var target_fov: float = base_fov + (dash_fov_boost if _is_dashing() else 0.0)
	camera.fov = lerpf(camera.fov, target_fov, clampf(fov_lerp_speed * delta, 0.0, 1.0))


# =====================================================================
# RÖRELSE
# =====================================================================
func _get_wish_direction() -> Vector3:
	## Returnerar önskad rörelseriktning i världskoordinater (längd 0-1).
	var input_vec: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_back"
	)
	return (transform.basis * Vector3(input_vec.x, 0.0, input_vec.y)).normalized()


func _apply_horizontal_movement(wish_dir: Vector3, delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var target := wish_dir * max_speed
	var accel: float

	if wish_dir != Vector3.ZERO:
		accel = ground_acceleration if is_on_floor() else air_acceleration
	else:
		accel = ground_friction if is_on_floor() else air_friction

	# move_toward ger snabb men mjuk acceleration/inbromsning.
	# Efter en dash (fart > max_speed) bromsas vi också naturligt ner.
	horizontal = horizontal.move_toward(target, accel * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


func _apply_gravity(delta: float) -> void:
	# Ingen gravitation under dash (ger en "rak" och tillfredsställande dash)
	if not is_on_floor() and not _is_dashing():
		velocity.y -= _gravity * gravity_multiplier * delta


# =====================================================================
# HOPP
# =====================================================================
func _handle_jump() -> void:
	# Hoppar om vi nyss tryckt hopp (buffer) OCH nyss stått på marken (coyote)
	if _jump_buffer_left > 0.0 and _coyote_left > 0.0:
		velocity.y = jump_velocity
		_jump_buffer_left = 0.0
		_coyote_left = 0.0

	# Variabel hopphöjd: släpper man knappen tidigt kapas hoppet
	if Input.is_action_just_released("jump") and velocity.y > 0.0:
		velocity.y *= jump_cut_factor


# =====================================================================
# DASH
# =====================================================================
func _handle_dash_input(wish_dir: Vector3) -> void:
	if Input.is_action_just_pressed("dash") and _can_dash():
		# Dasha dit man styr, eller rakt framåt om ingen riktning hålls
		_dash_direction = wish_dir if wish_dir != Vector3.ZERO else -global_transform.basis.z
		_dash_direction.y = 0.0
		_dash_direction = _dash_direction.normalized()

		_dash_time_left = dash_duration
		_dash_cooldown_left = dash_cooldown
		velocity.y = 0.0
		dashed.emit()


func _apply_dash_velocity() -> void:
	velocity.x = _dash_direction.x * dash_speed
	velocity.z = _dash_direction.z * dash_speed


func _can_dash() -> bool:
	return _dash_cooldown_left <= 0.0 and not _is_dashing()


func _is_dashing() -> bool:
	return _dash_time_left > 0.0


# =====================================================================
# TIMERS
# =====================================================================
func _update_timers(delta: float) -> void:
	# Coyote time: fylls på när vi står på marken, minskar i luften
	if is_on_floor():
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)

	# Jump buffer: fylls när hopp trycks
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_left = jump_buffer_time
	else:
		_jump_buffer_left = maxf(_jump_buffer_left - delta, 0.0)

	# Dash
	_dash_time_left = maxf(_dash_time_left - delta, 0.0)
	_dash_cooldown_left = maxf(_dash_cooldown_left - delta, 0.0)
	dash_charge_changed.emit(1.0 - (_dash_cooldown_left / dash_cooldown))


# =====================================================================
# INPUT-REGISTRERING (så att du slipper ställa in i Project Settings nu)
# =====================================================================
func _setup_input_actions() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("move_back", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("jump", KEY_SPACE)
	_add_key_action("dash", KEY_SHIFT)
	_add_mouse_action("shoot", MOUSE_BUTTON_LEFT)


func _add_key_action(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


func _add_mouse_action(action: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)
