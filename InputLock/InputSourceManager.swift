import Carbon
import Cocoa

struct InputSourceInfo {
    let id: String
    let name: String
    let icon: NSImage?
    let source: TISInputSource
}

enum InputSourceManager {
    static func currentID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return Unmanaged<CFString>.fromOpaque(
            TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        ).takeUnretainedValue() as String
    }

    static func currentName() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        return currentID()
    }

    static func allSources() -> [InputSourceInfo] {
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        var result: [InputSourceInfo] = []
        for source in sources {
            let category = Unmanaged<CFString>.fromOpaque(
                TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory)
            ).takeUnretainedValue() as String
            guard category == "TISCategoryKeyboardInputSource" else { continue }

            let selectable = Unmanaged<CFBoolean>.fromOpaque(
                TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            ).takeUnretainedValue()
            guard CFBooleanGetValue(selectable) else { continue }

            let id = Unmanaged<CFString>.fromOpaque(
                TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            ).takeUnretainedValue() as String

            let name: String
            if let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
                name = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            } else {
                name = id
            }
            result.append(InputSourceInfo(id: id, name: name, icon: iconForSource(source), source: source))
        }
        return result
    }

    static func switchTo(id: String) {
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        for source in sources {
            let sourceID = Unmanaged<CFString>.fromOpaque(
                TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            ).takeUnretainedValue() as String
            if sourceID == id {
                TISSelectInputSource(source)
                return
            }
        }
    }

    private static func iconForSource(_ source: TISInputSource) -> NSImage? {
        // 优先用 IconImageURL
        if let iconURLPtr = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) {
            let url = Unmanaged<CFURL>.fromOpaque(iconURLPtr).takeUnretainedValue() as URL
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                return image
            }
        }
        // 回退到 IconRef
        if let iconRefPtr = TISGetInputSourceProperty(source, kTISPropertyIconRef) {
            let iconRef = OpaquePointer(iconRefPtr)
            let image = NSImage(iconRef: iconRef)
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return nil
    }
}
