import SwiftUI
import IOBluetooth
import ObjectiveC

struct AirPodsMaxBattery: Identifiable {
    let id: String
    let name: String
    let percentage: Int?
}

enum AirPodsMaxBatteryReader {
    static func connectedDevices() -> [AirPodsMaxBattery] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.filter {
            $0.isConnected() && ($0.name ?? "").localizedCaseInsensitiveContains("AirPods Max")
        }.map { device in
            AirPodsMaxBattery(
                id: device.addressString ?? device.name ?? "AirPods Max",
                name: displayName(of: device),
                percentage: percentage(of: device)
            )
        }.sorted { $0.id < $1.id }
    }

    private static func displayName(of device: IOBluetoothDevice) -> String {
        let selector = NSSelectorFromString("getDisplayName")
        if device.responds(to: selector),
           let method = class_getInstanceMethod(type(of: device), selector),
           method_getNumberOfArguments(method) == 2 {
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            if String(cString: returnType) == "@",
               let name = device.perform(selector)?.takeUnretainedValue() as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return device.name ?? "AirPods Max"
    }

    private static func percentage(of device: IOBluetoothDevice) -> Int? {
        let selector = NSSelectorFromString("batteryPercentSingle")
        guard device.responds(to: selector),
              let method = class_getInstanceMethod(type(of: device), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "C" else { return nil }

        typealias BatteryGetter = @convention(c) (AnyObject, Selector) -> UInt8
        let getter = unsafeBitCast(method_getImplementation(method), to: BatteryGetter.self)
        let value = Int(getter(device, selector))
        return (0...100).contains(value) ? value : nil
    }
}

struct BatteriesView: View {
    @State private var devices: [AirPodsMaxBattery] = []
    @State private var hasRefreshed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Batteries")
                    .font(.headline)
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh battery levels")
                .accessibilityLabel("Refresh battery levels")
            }

            if devices.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "airpodsmax")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hasRefreshed ? "AirPods Max not connected" : "Checking AirPods Max…")
                            .font(.subheadline.weight(.medium))
                        Text("Connect your AirPods Max via Bluetooth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(devices) { device in
                    HStack(spacing: 14) {
                        Image(systemName: "airpodsmax")
                            .font(.system(size: 34))
                            .frame(width: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(device.percentage == nil ? "Battery unavailable" : "Connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let percentage = device.percentage {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(percentage)%")
                                    .font(.system(.title2, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                Image(systemName: batterySymbol(percentage))
                                    .foregroundStyle(percentage <= 20 ? Color.red : Color.green)
                            }
                        } else {
                            Text("—")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .task {
            while !Task.isCancelled {
                refresh()
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }

    private func refresh() {
        devices = AirPodsMaxBatteryReader.connectedDevices()
        hasRefreshed = true
    }

    private func batterySymbol(_ percentage: Int) -> String {
        switch percentage {
        case 0...10: return "battery.0percent"
        case 11...37: return "battery.25percent"
        case 38...62: return "battery.50percent"
        case 63...87: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
