extends GutTest

## The game once showed a VPN address instead of the Wi-Fi one, and the partner
## on the second laptop never got through. These checks keep the order right.

func _iface(name: String, addresses: Array) -> Dictionary:
	return {"name": name, "friendly": name, "addresses": addresses}

func test_wifi_address_wins_over_vpn() -> void:
	var picked := LocalAddresses.pick([
		_iface("utun4", ["10.8.1.5"]),
		_iface("en0", ["192.168.31.5"]),
	])
	assert_eq(picked[0], "192.168.31.5",
		"a VPN address is visible only to this machine and useless to a partner")

func test_virtual_interfaces_are_dropped_entirely() -> void:
	var picked := LocalAddresses.pick([
		_iface("utun0", ["10.8.1.5"]),
		_iface("awdl0", ["169.254.1.1"]),
		_iface("bridge100", ["192.168.64.1"]),
		_iface("en0", ["192.168.31.5"]),
	])
	assert_eq(picked, ["192.168.31.5"] as Array[String])

func test_ipv6_and_loopback_are_skipped() -> void:
	var picked := LocalAddresses.pick([
		_iface("lo0", ["127.0.0.1", "::1"]),
		_iface("en0", ["fe80::1", "192.168.31.5"]),
	])
	assert_eq(picked, ["192.168.31.5"] as Array[String])

func test_several_physical_interfaces_all_offered() -> void:
	# Ethernet and Wi-Fi at once: which of them is the right one, the player
	# knows.
	var picked := LocalAddresses.pick([
		_iface("en0", ["192.168.31.5"]),
		_iface("en5", ["192.168.31.9"]),
	])
	assert_eq(picked.size(), 2)

func test_unknown_interface_is_offered_last() -> void:
	var picked := LocalAddresses.pick([
		_iface("zz9", ["10.0.0.7"]),
		_iface("en0", ["192.168.31.5"]),
	])
	assert_eq(picked, ["192.168.31.5", "10.0.0.7"] as Array[String],
		"an unknown interface is not discarded, but not put first either")

func test_no_network_at_all_is_not_a_crash() -> void:
	assert_eq(LocalAddresses.pick([]).size(), 0)
	assert_eq(LocalAddresses.pick([_iface("lo0", ["127.0.0.1"])]).size(), 0)

func test_duplicates_are_not_repeated() -> void:
	var picked := LocalAddresses.pick([
		_iface("en0", ["192.168.31.5", "192.168.31.5"]),
	])
	assert_eq(picked.size(), 1)

func test_this_machine_reports_something_sane() -> void:
	for address in LocalAddresses.of_this_machine():
		assert_false(address.begins_with("127."), "a loopback address is useless to a partner")
		assert_false(address.contains(":"), "the address must be version four")
