class_name RoomLink

## A room's code carried in the page address, `…/?room=ABC234`: sent from one phone's
## share sheet, opened in another's browser, and the game starts on the join screen
## with the code in. It never joins by itself — see NetScreen.prefill.

const KEY := "room"

## The code as the link carries it: raw, a stranger's text. It goes through
## `clean_code` before anything shows or sends it.
static func code_in(page: String) -> String:
	var mark := page.find("?")
	if mark < 0:
		return ""
	var query := page.substr(mark + 1)
	var anchor := query.find("#")
	if anchor >= 0:
		query = query.substr(0, anchor)
	return RelayConfig.query_value(query, KEY)

## This page, with the code and nothing else behind it: a `?selftest` or a `?relay`
## of our own has no business in a friend's link.
static func url_for(page: String, code: String) -> String:
	var base := page
	for mark in ["?", "#"]:
		var at := base.find(mark)
		if at >= 0:
			base = base.substr(0, at)
	return base + "?" + KEY + "=" + code

## Hands the link to the phone's share sheet, or copies it where there is none.
## "shared", "copied", or "" with nothing to do it with. The browser answers later
## and may say no — a share cancelled, a clipboard refused — and neither is worth a
## word on screen: the code is right there, large enough to dictate.
static func send(url: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var how = JavaScriptBridge.eval(SEND % JSON.stringify(url), true)
	return how if typeof(how) == TYPE_STRING else ""

const SEND := """(function (url) {
  if (navigator.share) {
    navigator.share({ url: url }).catch(function () {});
    return 'shared';
  }
  if (navigator.clipboard) {
    navigator.clipboard.writeText(url).catch(function () {});
    return 'copied';
  }
  return '';
})(%s)"""
