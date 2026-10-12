# AirPods Max battery experiment

Branch: `battery-test`

Open `boringNotch.xcodeproj`, select the `boringNotch` scheme and My Mac, then run.
Expand the notch and select the battery icon beside Home and Shelf. If tabs are
hidden, enable “Always show tabs” in settings. The Batteries tab remains available
when the Shelf feature is disabled.

The panel shows connected paired devices whose Bluetooth name contains
“AirPods Max”. It uses Apple's SF Symbols for the headphones and battery.
Readings refresh on opening the panel, every 15 seconds while visible, and on
pressing Refresh. Disconnecting the headphones clears the reading on the next
refresh. An unsupported battery getter or a value outside 0–100 displays “—”.

This is experimental: `IOBluetoothDevice.batteryPercentSingle` is undocumented.
The implementation verifies the selector's presence and unsigned-byte return type
before calling it. Values come from macOS's Bluetooth cache; refreshing the panel
does not force the headphones to transmit a new reading. The custom label uses the guarded, undocumented `getDisplayName` getter,
with the remote Bluetooth name as a fallback.

Validation on the connected AirPods Max: the production reader returned 30%,
including from a signed sandboxed test app with the Bluetooth entitlement.

Manual checks: open Batteries, switch to Home/Shelf and back, disconnect and
refresh, reconnect and refresh. Check that only connected AirPods Max appear.
