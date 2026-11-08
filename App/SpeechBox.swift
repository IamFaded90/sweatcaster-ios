// Bevarer én talesyntetisator gennem SwiftUI-visningens levetid.

import AVFAudio
import SwiftUI

final class SpeechBox: ObservableObject {
    let synthesizer = AVSpeechSynthesizer()
}
