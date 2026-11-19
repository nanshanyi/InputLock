import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var locked = true
    var lockedInputID = ""
    var lockItem: NSMenuItem!
    var launchItem: NSMenuItem!
    var inputSourceItems: [NSMenuItem] = []
    var enforceScheduled = false
    var retryWorkItem: DispatchWorkItem?
    var pollTimer: Timer?
    var lastObservedID = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        lockedInputID = InputSourceManager.currentID()
        lastObservedID = lockedInputID
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusTitle()
        buildMenu()
        statusItem.menu = menu

        // AppKit 会在 App 非激活时挂起分布式通知的投递（默认 .coalesce 只会排队合并），
        // 菜单栏 App 几乎一直处于非激活状态，必须显式要求立即投递。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // 切换 App（“自动切换到文稿的输入法”）、唤醒、解锁屏幕时系统可能恢复别的输入法
        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            wsCenter.addObserver(self, selector: #selector(inputSourceChanged), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // 兜底轮询：通知丢失或被合并时也能在 1 秒内纠正
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCurrentSource()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func updateLockItem() {
        if locked {
            let sources = InputSourceManager.allSources()
            let lockName = sources.first(where: { $0.id == lockedInputID })?.name ?? "未知"
            lockItem.title = "锁定：\(lockName)"
            lockItem.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "locked")
        } else {
            lockItem.title = "锁定：已关闭"
            lockItem.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "unlocked")
        }
    }

    func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        // 锁定开关
        lockItem = NSMenuItem(title: "锁定：\(InputSourceManager.currentName())", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "locked")
        menu.addItem(lockItem)

        menu.addItem(NSMenuItem.separator())

        // 输入法列表 header
        let header = NSMenuItem(title: "输入法列表", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = 100
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())

        // 开机自启
        launchItem = NSMenuItem(title: launchAtLoginEnabled() ? "✅ 开机自启" : "⬜ 开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func refreshInputSourceList() {
        // 移除旧的输入法菜单项
        for item in inputSourceItems { menu.removeItem(item) }
        inputSourceItems.removeAll()

        let sources = InputSourceManager.allSources()
        let currentID = InputSourceManager.currentID()

        // 找到 header 的位置
        guard let headerIndex = menu.items.firstIndex(where: { $0.tag == 100 }) else { return }
        var insertAt = headerIndex + 1

        for info in sources {
            let isCurrent = info.id == currentID
            let isLockTarget = info.id == lockedInputID
            var title = info.name
            if isCurrent { title = "▶ \(info.name)" }

            let item = NSMenuItem(title: "", action: #selector(selectInputSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = info.id
            item.image = info.icon

            if isLockTarget && locked {
                let attrStr = NSMutableAttributedString(string: title + " ")
                let attachment = NSTextAttachment()
                attachment.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "locked")
                let attachStr = NSAttributedString(attachment: attachment)
                attrStr.append(attachStr)
                item.attributedTitle = attrStr
            } else {
                item.title = title
            }

            menu.insertItem(item, at: insertAt)
            inputSourceItems.append(item)
            insertAt += 1
        }
    }

    func updateStatusTitle() {
        statusItem.button?.title = ""
        let currentID = InputSourceManager.currentID()
        let sources = InputSourceManager.allSources()
        let baseIcon = sources.first(where: { $0.id == currentID })?.icon

        if locked, let base = baseIcon {
            statusItem.button?.image = compositeIcon(base: base, locked: true)
        } else if let base = baseIcon {
            statusItem.button?.image = base
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "keyboard")
        }
    }

    func compositeIcon(base: NSImage, locked: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let result = NSImage(size: size, flipped: false) { rect in
            // 输入法图标缩小放左上，给右下角 lock 留空间
            base.draw(in: NSRect(x: 0, y: 6, width: 14, height: 14))

            if locked, let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
                // lock 放右下角，不重叠
                lock.draw(in: NSRect(x: 12, y: 0, width: 10, height: 10))
            }
            return true
        }
        result.isTemplate = true
        return result
    }

    /// 任何可能导致输入法变化的事件都走这里。不再丢弃事件，而是合并到下一轮 runloop 统一检查，
    /// 让系统先完成它自己的切换，再读取最终状态。
    @objc func inputSourceChanged() {
        guard !enforceScheduled else { return }
        enforceScheduled = true
        DispatchQueue.main.async {
            self.enforceScheduled = false
            self.enforceLock(attempt: 0)
        }
    }

    func pollCurrentSource() {
        let currentID = InputSourceManager.currentID()
        if currentID != lastObservedID || (locked && currentID != lockedInputID) {
            inputSourceChanged()
        }
    }

    /// 切回锁定输入法，并在短延迟后复查。TISSelectInputSource 对中日韩输入法偶尔不生效，
    /// 或被系统随后的切换覆盖，所以需要校验 + 重试。
    func enforceLock(attempt: Int) {
        retryWorkItem?.cancel()
        retryWorkItem = nil

        let currentID = InputSourceManager.currentID()
        if currentID != lastObservedID {
            lastObservedID = currentID
            updateStatusTitle()
        }
        guard locked, currentID != lockedInputID else { return }

        InputSourceManager.switchTo(id: lockedInputID)
        lastObservedID = InputSourceManager.currentID()
        updateStatusTitle()

        let maxAttempts = 5
        guard attempt + 1 < maxAttempts else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.enforceLock(attempt: attempt + 1)
        }
        retryWorkItem = item
        // 0.05s, 0.1s, 0.2s, 0.4s 递增复查
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * pow(2, Double(attempt)), execute: item)
    }

    @objc func selectInputSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if locked { lockedInputID = id }
        InputSourceManager.switchTo(id: id)
        lastObservedID = InputSourceManager.currentID()
        updateStatusTitle()
        if locked { enforceLock(attempt: 0) }
    }

    @objc func toggleLock() {
        locked.toggle()
        if locked {
            lockedInputID = InputSourceManager.currentID()
        }
        updateLockItem()
        updateStatusTitle()
    }

    @objc func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                print("Launch at login error: \(error)")
            }
            launchItem.title = service.status == .enabled ? "✅ 开机自启" : "⬜ 开机自启"
        }
    }

    func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshInputSourceList()
        updateLockItem()
    }
}
