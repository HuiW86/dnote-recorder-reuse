// Command whitelist (prd.md §2.2, CLAUDE.md rule 1).
//
// Only the commands below exist in code, so upper layers cannot send anything else.
// Irreversible commands (factory reset, format, firmware upgrade) and card WiFi upload
// are never defined. M3/M4 commands are added here when their milestone starts.

/// Commands the app may send to the card. Raw value is the frame CMD byte.
public enum Command: UInt8, CaseIterable, Sendable {
    // Queries
    case deviceInfo = 0x80
    case switches = 0x81
    case recordingStatus = 0x56
    case bondStatus = 0xA1
    case encryptionStatus = 0xA3

    // Settings; each replies with a single 0x01 byte (PROTOCOL.md §4.1)
    case setLED = 0x83
    case setMotor = 0x84
    case setNoiseCancel = 0x85
    case syncTime = 0x87
    case setVAD = 0x8B
    case setGain = 0x8C
    case setNoiseLevel = 0x8D
    case setAutoOff = 0x8F

    // Recording
    case stopRecording = 0x50
    case startRecording = 0x51
    case pauseRecording = 0x52
    case resumeRecording = 0x53

    // Files
    case fileData = 0x70
    case listFiles = 0x90
    case deleteFile = 0x91

    // Pairing
    case bond = 0xA0
    case setEncryptionKey = 0xA2
}

/// Frames the card pushes on its own; they are never sent by the app.
public enum DevicePush: UInt8, Sendable {
    /// `{name}` of a recording started with the card button.
    case recordingStarted = 0x54
    /// Empty payload after a recording stops.
    case recordingStopped = 0x55
}
