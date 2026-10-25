import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}
