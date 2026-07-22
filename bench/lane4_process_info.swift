import Foundation

let processInfo = ProcessInfo.processInfo
let thermalState: String

switch processInfo.thermalState {
case .nominal:
    thermalState = "nominal"
case .fair:
    thermalState = "fair"
case .serious:
    thermalState = "serious"
case .critical:
    thermalState = "critical"
@unknown default:
    thermalState = "unknown"
}

let payload: [String: Any] = [
    "schema": "glacier.decode-lane4/process-info-v1",
    "thermal_state": thermalState,
    "low_power_mode_enabled": processInfo.isLowPowerModeEnabled,
]
let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data([0x0a]))
