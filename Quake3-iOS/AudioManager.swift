import AVFoundation
import Foundation

/// Drives iOS audio output for Q3's mixed PCM stream.
/// Ported from Q2_too_ios AudioManager.swift; adapted for Q3 bridge names.
final class Q3AudioManager: @unchecked Sendable {
    static let shared = Q3AudioManager()
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configuredSampleRate: Double = 0
    private var didStart = false
    private var notificationToken: NSObjectProtocol?
    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            configuredSampleRate = session.sampleRate
        } catch {
            NSLog("[Q3-AUDIO] session activation failed: %@", error.localizedDescription)
            configuredSampleRate = 44100
        }
        Q3IOS_AudioSetSampleRate(Int32(configuredSampleRate.rounded()))
        NSLog("[Q3-AUDIO] session sampleRate=%.0f", configuredSampleRate)
        attachSourceNode()
        startEngine()
        notificationToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) }
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        if let token = notificationToken {
            NotificationCenter.default.removeObserver(token)
            notificationToken = nil
        }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
    }

    private func attachSourceNode() {
        guard sourceNode == nil else { return }
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: configuredSampleRate,
                                         channels: 2, interleaved: true)
        guard let sourceFormat else {
            NSLog("[Q3-AUDIO] could not build source format @ %.0f Hz", configuredSampleRate)
            return
        }
        let node = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            // Access the first buffer directly from the AudioBufferList
            let firstBuffer = audioBufferList.pointee.mBuffers
            guard let mData = firstBuffer.mData else { return noErr }
            let dest = mData.assumingMemoryBound(to: Int16.self)
            _ = Q3IOS_AudioPullStereo16(dest, Int32(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        sourceNode = node
    }

    private func startEngine() {
        do { try engine.start(); NSLog("[Q3-AUDIO] AVAudioEngine started") }
        catch { NSLog("[Q3-AUDIO] engine start failed: %@", error.localizedDescription) }
    }

    private func handleInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began: engine.pause()
        case .ended:
            if let optionRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
                if options.contains(.shouldResume) { startEngine() }
            }
        @unknown default: break
        }
    }
}
