class_name CodeField
extends Node

## A real text field over the game, for a room code on a phone. It has to be the
## page's own and tapped by the person: iOS opens its keyboard only for a field
## focused inside the tap itself, and the engine reads a tap a frame later, so a
## field the game focused would sit there with no keyboard.
##
## What is typed is cleaned on the page before it is cut to six: a pasted
## `ABC-234` cut first would lose its last character to the dash. The screen
## cleans it again, as it cleans a key or a link.

signal changed(text: String)
signal submitted(text: String)

const ID := "room-code-field"

## Kept, or the browser would be left calling callbacks already freed.
var _on_input: JavaScriptObject = null
var _on_enter: JavaScriptObject = null

## False off the web: there is no page to put a field on.
func open(text: String) -> bool:
	if not OS.has_feature("web"):
		return false
	_on_input = JavaScriptBridge.create_callback(_input_came)
	_on_enter = JavaScriptBridge.create_callback(_enter_came)
	var window := JavaScriptBridge.get_interface("window")
	window.roomCodeInput = _on_input
	window.roomCodeEnter = _on_enter
	JavaScriptBridge.eval(OPEN % [JSON.stringify(ID), JSON.stringify(text)])
	return true

## Follow the code's rectangle in the game, mapped to the page's canvas.
func place(rect: Rect2, view: Vector2) -> void:
	if not OS.has_feature("web") or _on_input == null:
		return
	JavaScriptBridge.eval(PLACE % [JSON.stringify(ID),
		JSON.stringify([rect.position.x / view.x, rect.position.y / view.y,
			rect.size.x / view.x, rect.size.y / view.y])])

func close() -> void:
	if not OS.has_feature("web") or _on_input == null:
		return
	JavaScriptBridge.eval(CLOSE % JSON.stringify(ID))
	_on_input = null
	_on_enter = null

func _exit_tree() -> void:
	close()

func _input_came(args: Array) -> void:
	changed.emit(str(args[0]) if not args.is_empty() else "")

func _enter_came(args: Array) -> void:
	submitted.emit(str(args[0]) if not args.is_empty() else "")

## Formatted with `%`: a percent sign of its own is written `%%`.
const OPEN := """(function (id, text) {
  var old = document.getElementById(id);
  if (old) old.remove();
  var f = document.createElement('input');
  f.id = id;
  f.value = text;
  f.placeholder = 'TAP HERE';
  f.setAttribute('aria-label', 'Room code');
  f.autocapitalize = 'characters';
  f.autocomplete = 'off';
  f.spellcheck = false;
  f.enterKeyHint = 'go';
  f.style.cssText = 'position:fixed;left:50%%;top:0;transform:translateX(-50%%);' +
    'z-index:10;box-sizing:border-box;padding:4px;font-weight:bold;font-family:monospace;' +
    'text-align:center;text-transform:uppercase;color:#ffd933;background:#000;' +
    'border:2px solid #fff;border-radius:0;';
  f.addEventListener('focus', function () { f.placeholder = ''; });
  f.addEventListener('blur', function () { f.placeholder = 'TAP HERE'; });
  f.addEventListener('input', function () {
    var clean = f.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
    if (clean !== f.value) f.value = clean;
    window.roomCodeInput(f.value);
  });
  f.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); window.roomCodeEnter(f.value); }
  });
  document.body.appendChild(f);
})(%s, %s)"""

const CLOSE := """(function (id) {
  var f = document.getElementById(id);
  if (f) { f.blur(); f.remove(); }
})(%s)"""

const PLACE := """(function (id, area) {
  var f = document.getElementById(id);
  if (!f) return;
  var c = document.getElementById('canvas').getBoundingClientRect();
  var height = area[3] * c.height;
  f.style.left = (c.left + (area[0] + area[2] / 2) * c.width) + 'px';
  f.style.top = (c.top + area[1] * c.height) + 'px';
  f.style.width = (area[2] * c.width) + 'px';
  f.style.height = height + 'px';
  f.style.fontSize = (height * 0.62) + 'px';
  f.style.letterSpacing = (height * 0.07) + 'px';
})(%s, %s)"""
