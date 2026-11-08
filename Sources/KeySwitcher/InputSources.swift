import Carbon
import Foundation
import KeySwitcherCore

/// Reads and switches the system keyboard layout.
final class InputSources {
    private var sources: [LayoutKind: TISInputSource] = [:]
    var onChange: ((LayoutKind?) -> Void)?

    init() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for s in list {
                if let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) {
                    let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
                    if let k = LayoutKind(inputSourceID: id) { sources[k] = s }
                }
            }
        }
        let center = CFNotificationCenterGetDistributedCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<InputSources>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { me.onChange?(me.current) }
        }, kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
    }

    var current: LayoutKind? {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        return LayoutKind(inputSourceID: id)
    }

    func select(_ kind: LayoutKind) {
        guard let s = sources[kind], current != kind else { return }
        TISSelectInputSource(s)
    }
}
