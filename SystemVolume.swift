//
//  SystemVolume.swift
//  HyperVibe
//
//  CoreAudio volume read/write + a listener-based revert guard that reverses
//  AVRCP-origin volume changes during a short window after a remote volume HID press.
//

import AudioToolbox
import CoreAudio
import Foundation

enum SystemVolume {
    static func get() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func set(_ volume: Float) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var v = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &v)
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (status == noErr && id != 0) ? id : nil
    }
}

/// Reverts AVRCP-origin volume changes caused by the Siri Remote's volume buttons.
///
/// Design: a CoreAudio listener continuously tracks system volume. It maintains a
/// `baselineVolume` that lags real volume by `settleDelay` — any observed change stays
/// provisional for that interval. If a remote volume HID press (`armFromRemoteButton()`)
/// arrives during the settle window, we retroactively revert to the pre-change baseline.
/// During a 500ms guard window after a press, further changes are reverted immediately.
///
/// Why lagged baseline: BT AVRCP can beat the HID callback to main. A plain snapshot-on-
/// press approach captures the post-change volume and has nothing to revert to. By holding
/// changes provisional for ~150ms, the HID press still has time to claim the change.
///
/// Keyboard/other-origin volume changes (outside a guard window with no close HID press)
/// pass through normally — after `settleDelay` they become the new baseline.
final class VolumeRevertGuard {
    static let shared = VolumeRevertGuard()

    private var baselineVolume: Float?
    private var guardUntil: Date = .distantPast
    private let guardWindow: TimeInterval = 0.5
    private let settleDelay: TimeInterval = 0.15
    private var pendingSettle: DispatchWorkItem?
    private var listenerInstalled = false
    private var listenerDeviceID: AudioObjectID = 0

    /// Output devices quantize volume to their own discrete steps, so a reverted value can
    /// come back slightly different from the baseline we wrote. Treat anything this close
    /// as "matches baseline" (device steps are ~1/16 = 0.0625; this stays well under one).
    private let matchEpsilon: Float = 0.02
    /// Storm breaker: if the device refuses to hold our revert value (quantization snaps it
    /// back), stop fighting after this many attempts and adopt the device's value.
    private let maxRevertAttempts = 2
    private var lastRevertObserved: Float?
    private var revertAttempts = 0

    /// Install the CoreAudio listener and capture the starting baseline at app launch,
    /// so the first remote volume press has something to revert to.
    func prewarm() {
        ensureListener()
        if baselineVolume == nil {
            baselineVolume = SystemVolume.get()
        }
        rmDebug("🔊 VolumeRevertGuard prewarm: listener=\(listenerInstalled) baseline=\(baselineVolume.map { String(format: "%.3f", $0) } ?? "nil")")
    }

    /// Called on every volume HID press from the remote. Opens the guard window and, if a
    /// volume change landed in the last `settleDelay` ms, reverts it retroactively — this
    /// handles the common case where AVRCP beats HID to the main thread.
    func armFromRemoteButton() {
        ensureListener()
        guardUntil = Date().addingTimeInterval(guardWindow)
        if pendingSettle != nil, let baselineValue = baselineVolume {
            pendingSettle?.cancel()
            pendingSettle = nil
            SystemVolume.set(baselineValue)
        }
    }

    /// Called just before the app itself writes a volume value (synthetic System Volume
    /// step). The target becomes the baseline so the listener treats the write — and the
    /// output device's quantized version of it, within matchEpsilon — as expected, and the
    /// guard window opens so an AVRCP straggler landing right behind it gets reverted to
    /// the stepped value instead of stacking on top of it.
    func expect(_ target: Float) {
        ensureListener()
        pendingSettle?.cancel()
        pendingSettle = nil
        baselineVolume = max(0, min(1, target))
        guardUntil = Date().addingTimeInterval(guardWindow)
        lastRevertObserved = nil
        revertAttempts = 0
    }

    private func ensureListener() {
        guard !listenerInstalled, let id = SystemVolume.defaultOutputDeviceID() else { return }
        listenerDeviceID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.onVolumeChanged()
        }
        if status == noErr {
            listenerInstalled = true
        }
    }

    private func onVolumeChanged() {
        guard let current = SystemVolume.get() else {
            rmDebug("🔊 listener fired but SystemVolume.get() returned nil")
            return
        }
        let baselineStr = baselineVolume.map { String(format: "%.3f", $0) } ?? "nil"
        let inWindow = Date() < guardUntil
        rmDebug("🔊 listener: current=\(String(format: "%.3f", current)) baseline=\(baselineStr) inGuard=\(inWindow)")

        // Our own revert write echoes back as a listener callback; noop when it matches
        // (within device-quantization tolerance).
        if let baseline = baselineVolume, abs(current - baseline) < matchEpsilon {
            rmDebug("🔊 listener: match baseline, noop")
            lastRevertObserved = nil
            revertAttempts = 0
            return
        }

        if inWindow, let baseline = baselineVolume {
            // Same off-baseline value observed again right after a revert = the device
            // quantized our write away. Stop fighting and adopt the device's value.
            if let last = lastRevertObserved, abs(current - last) < 0.001 {
                revertAttempts += 1
                if revertAttempts >= maxRevertAttempts {
                    rmDebug("🔊 listener: revert not holding at \(String(format: "%.3f", current)) — adopting as baseline")
                    baselineVolume = current
                    lastRevertObserved = nil
                    revertAttempts = 0
                    return
                }
            } else {
                lastRevertObserved = current
                revertAttempts = 0
            }
            rmDebug("🔊 listener: reverting \(String(format: "%.3f", current)) → \(String(format: "%.3f", baseline))")
            SystemVolume.set(baseline)
            return
        }
        // Outside guard: defer committing this as the new baseline. If a remote HID press
        // arrives within settleDelay, it retroactively reverts instead.
        let captured = current
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.baselineVolume = captured
            self?.pendingSettle = nil
            rmDebug("🔊 settle: baseline committed = \(String(format: "%.3f", captured))")
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }
}
