class_name LocalAddresses

## The address a partner on the local network can actually type in.
##
## The engine's naive list is no good for this: the first entry is usually a
## VPN or a housekeeping interface visible only to this machine. A player types
## it on the second laptop and never gets through — exactly that case.

## Interfaces whose address is useless to another machine: VPN, AirDrop,
## virtual machine bridges, Apple's housekeeping channels.
const VIRTUAL := ["utun", "ppp", "ipsec", "awdl", "llw", "bridge",
	"vmnet", "tun", "tap", "gif", "stf", "anpi", "ap1"]

## Wired and wireless interfaces come first: they are the ones facing the
## network the partner sits on.
const PHYSICAL := ["en", "eth", "wl"]

## The pure part: from the engine's list of interfaces, the usable addresses in
## descending order of usefulness. Tested without any network at all.
static func pick(interfaces: Array) -> Array[String]:
	var physical: Array[String] = []
	var other: Array[String] = []
	for entry in interfaces:
		var name: String = entry.get("name", "")
		if _is_virtual(name):
			continue
		for address in entry.get("addresses", []):
			if not _is_usable_ipv4(address):
				continue
			if _is_physical(name):
				if not physical.has(address):
					physical.append(address)
			elif not other.has(address):
				other.append(address)
	physical.append_array(other)
	return physical

static func of_this_machine() -> Array[String]:
	return pick(IP.get_local_interfaces())

static func _is_virtual(name: String) -> bool:
	for prefix in VIRTUAL:
		if name.begins_with(prefix):
			return true
	return false

static func _is_physical(name: String) -> bool:
	for prefix in PHYSICAL:
		if name.begins_with(prefix):
			return true
	return false

static func _is_usable_ipv4(address: String) -> bool:
	if address.contains(":"):
		return false
	return not address.begins_with("127.")
