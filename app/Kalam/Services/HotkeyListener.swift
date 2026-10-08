import Foundation
import AppKit
import HotKey
import OSLog

// MARK: - Global Hotkey (press-to-talk)

final class HotkeyListener {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "Hotkey")
    private var hotKey: HotKey?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var activePreset: KeyCombination?
    /// settings redesign: custom bare-modifier hotkey — active while THIS keyCode is down.
    private var activeCustomModifierKeyCode: UInt16?
    private var modifierHotkeyIsDown = false
    private var lastRelevantFlags: NSEvent.ModifierFlags = []
    private var leftCommandDown = false
    private var rightCommandDown = false
    private var leftOptionDown = false
    private var rightOptionDown = false
    private var leftShiftDown = false
    private var rightShiftDown = false
    private var leftControlDown = false
    private var rightControlDown = false
    var onPTTChanged: ((Bool) -> Void)?
    
    func start() {
        update(configuration: PTTHotkeyConfiguration.load())
    }

    func update(configuration: PTTHotkeyConfiguration) {
        stopModifierMonitoring()
        hotKey = nil

        let safeConfiguration = configuration.normalized()
        // Mode telemetry: the effective activation mode decides the whole PTT
        // contract — log it next to the key so a settings/mode mismatch can
        // never hide in a behavior report again (holdOrToggle double-press
        // regression, 2026-09-10).
        logger.info("PTT activation mode=\(safeConfiguration.activationMode.rawValue, privacy: .public)")
        if let custom = safeConfiguration.customChord {
            registerCustom(custom)
            return
        }
        if let modifierOnlyFlags = safeConfiguration.keyCombination.modifierOnlyFlags {
            startModifierMonitoring(requiredFlags: modifierOnlyFlags, preset: safeConfiguration.keyCombination)
            logger.info("Hotkey registered \(safeConfiguration.keyCombination.displayName, privacy: .public)")
            return
        }

        // Use HotKey for key+modifier combinations.
        let resolved = safeConfiguration.resolvedHotkey
        hotKey = HotKey(key: resolved.key.hotKeyValue, modifiers: resolved.modifiers)

        hotKey?.keyDownHandler = { [weak self] in
            self?.onPTTChanged?(true)
        }
        hotKey?.keyUpHandler = { [weak self] in
            self?.onPTTChanged?(false)
        }

        logger.info("Hotkey registered \(safeConfiguration.displayString, privacy: .public)")
    }

    // MARK: - settings redesign custom chord registration ("Record shortcut…")

    private func registerCustom(_ chord: KeyChord) {
        if Self.isModifierKeyCode(chord.keyCode) {
            startCustomModifierMonitoring(keyCode: chord.keyCode)
            logger.info("Hotkey registered custom modifier \(chord.displayVerbose, privacy: .public)")
            return
        }
        guard let key = Key(carbonKeyCode: UInt32(chord.keyCode)) else {
            logger.warning("Hotkey custom chord unsupported keyCode=\(chord.keyCode, privacy: .public)")
            return
        }
        hotKey = HotKey(key: key, modifiers: NSEvent.ModifierFlags(rawValue: chord.modifiersRaw))
        hotKey?.keyDownHandler = { [weak self] in
            self?.onPTTChanged?(true)
        }
        hotKey?.keyUpHandler = { [weak self] in
            self?.onPTTChanged?(false)
        }
        logger.info("Hotkey registered custom \(chord.displayVerbose, privacy: .public)")
    }

    /// Modifier virtual key codes: right/left cmd, opt, ctrl, shift (fn removed 2026-10-02 — unreliable trigger).
    private static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        [54, 55, 58, 59, 60, 61, 62].contains(keyCode)
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 54, 55: return .command
        case 61, 58: return .option
        case 60, 56: return .shift
        case 62, 59: return .control
        default: return []
        }
    }

    private func startCustomModifierMonitoring(keyCode: UInt16) {
        activeModifierFlags = Self.modifierFlag(for: keyCode)
        activePreset = nil
        activeCustomModifierKeyCode = keyCode
        modifierHotkeyIsDown = false
        lastRelevantFlags = []
        leftCommandDown = false
        rightCommandDown = false
        leftOptionDown = false
        rightOptionDown = false
        leftShiftDown = false
        rightShiftDown = false
        leftControlDown = false
        rightControlDown = false

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func startModifierMonitoring(requiredFlags: NSEvent.ModifierFlags, preset: KeyCombination) {
        activeModifierFlags = requiredFlags.intersection([.command, .option, .shift, .control, .function])
        activePreset = preset
        activeCustomModifierKeyCode = nil
        modifierHotkeyIsDown = false
        lastRelevantFlags = []
        leftCommandDown = false
        rightCommandDown = false
        leftOptionDown = false
        rightOptionDown = false
        leftShiftDown = false
        rightShiftDown = false
        leftControlDown = false
        rightControlDown = false

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func stopModifierMonitoring() {
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        activeModifierFlags = []
        activePreset = nil
        activeCustomModifierKeyCode = nil
        modifierHotkeyIsDown = false
        lastRelevantFlags = []
        leftCommandDown = false
        rightCommandDown = false
        leftOptionDown = false
        rightOptionDown = false
        leftShiftDown = false
        rightShiftDown = false
        leftControlDown = false
        rightControlDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !activeModifierFlags.isEmpty else { return }
        let relevant = event.modifierFlags.intersection([.command, .option, .shift, .control, .function])
        updateSideState(for: event.keyCode, flags: relevant)
        lastRelevantFlags = relevant
        let isDown = isPresetCurrentlyActive(relevantFlags: relevant)

        if isDown == modifierHotkeyIsDown { return }
        modifierHotkeyIsDown = isDown
        onPTTChanged?(isDown)
    }

    private func updateSideState(for keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        switch keyCode {
        case 54:
            rightCommandDown = resolveSideKeyState(current: rightCommandDown, relevantFlag: .command, newFlags: flags)
        case 55:
            leftCommandDown = resolveSideKeyState(current: leftCommandDown, relevantFlag: .command, newFlags: flags)
        case 61:
            rightOptionDown = resolveSideKeyState(current: rightOptionDown, relevantFlag: .option, newFlags: flags)
        case 58:
            leftOptionDown = resolveSideKeyState(current: leftOptionDown, relevantFlag: .option, newFlags: flags)
        case 60:
            rightShiftDown = resolveSideKeyState(current: rightShiftDown, relevantFlag: .shift, newFlags: flags)
        case 56:
            leftShiftDown = resolveSideKeyState(current: leftShiftDown, relevantFlag: .shift, newFlags: flags)
        case 62:
            rightControlDown = resolveSideKeyState(current: rightControlDown, relevantFlag: .control, newFlags: flags)
        case 59:
            leftControlDown = resolveSideKeyState(current: leftControlDown, relevantFlag: .control, newFlags: flags)
        default:
            break
        }

        if !flags.contains(.command) {
            leftCommandDown = false
            rightCommandDown = false
        }
        if !flags.contains(.option) {
            leftOptionDown = false
            rightOptionDown = false
        }
        if !flags.contains(.shift) {
            leftShiftDown = false
            rightShiftDown = false
        }
        if !flags.contains(.control) {
            leftControlDown = false
            rightControlDown = false
        }
    }

    private func resolveSideKeyState(current: Bool, relevantFlag: NSEvent.ModifierFlags, newFlags: NSEvent.ModifierFlags) -> Bool {
        let oldContains = lastRelevantFlags.contains(relevantFlag)
        let newContains = newFlags.contains(relevantFlag)
        if oldContains != newContains {
            return newContains
        }
        return !current
    }

    private func isPresetCurrentlyActive(relevantFlags: NSEvent.ModifierFlags) -> Bool {
        // settings redesign custom bare modifier: active only while the exact keyCode is down.
        if let customKeyCode = activeCustomModifierKeyCode {
            return isSideKeyDown(customKeyCode) && relevantFlags == activeModifierFlags
        }

        guard let activePreset else {
            return relevantFlags == activeModifierFlags
        }

        func matchesExactly(_ expected: NSEvent.ModifierFlags) -> Bool {
            relevantFlags == expected
        }

        switch activePreset {
        case .rightCommand:
            return rightCommandDown && !leftCommandDown && matchesExactly([.command])
        case .rightOption:
            return rightOptionDown && !leftOptionDown && matchesExactly([.option])
        case .rightShift:
            return rightShiftDown && !leftShiftDown && matchesExactly([.shift])
        case .rightControl:
            return rightControlDown && !leftControlDown && matchesExactly([.control])
        case .optionCommand, .controlCommand, .controlOption, .shiftCommand, .optionShift, .controlShift:
            return matchesExactly(activeModifierFlags)
        case .notSpecified:
            return matchesExactly(activeModifierFlags)
        }
    }

    private func isSideKeyDown(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54: return rightCommandDown
        case 55: return leftCommandDown
        case 61: return rightOptionDown
        case 58: return leftOptionDown
        case 60: return rightShiftDown
        case 56: return leftShiftDown
        case 62: return rightControlDown
        case 59: return leftControlDown
        default: return false
        }
    }

    deinit {
        stopModifierMonitoring()
    }
}
