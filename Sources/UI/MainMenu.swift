import AppKit

/// The main menu. Pourtype stays a menu-bar app (accessory activation policy), so this menu is never shown;
/// it exists for its key equivalents, which AppKit only finds in a main menu: without it ⌘C, ⌘V, ⌘X, ⌘A,
/// ⌘Z, ⌘W and ⌘Q do nothing in the History, Settings and Learn my typing windows. Every action goes to
/// the first responder or NSApp, as in any Mac app. It holds no ⇧⌘V or ⇧⌘C: those belong to the global
/// shortcuts, which Carbon delivers before any menu sees the keys anyway.
enum MainMenu {
    static func make(settingsTarget: AnyObject?, settingsAction: Selector?) -> NSMenu {
        let bar = NSMenu()

        let app = submenu(bar, "Pourtype")
        if let settingsAction {
            app.addItem(item(L.t("设置…", "Settings…"), settingsAction, ",", target: settingsTarget))
            app.addItem(.separator())
        }
        app.addItem(item(L.t("隐藏 Pourtype", "Hide Pourtype"), #selector(NSApplication.hide(_:)), "h", target: NSApp))
        app.addItem(.separator())
        app.addItem(item(L.t("退出 Pourtype", "Quit Pourtype"), #selector(NSApplication.terminate(_:)), "q", target: NSApp))

        let edit = submenu(bar, L.t("编辑", "Edit"))
        edit.addItem(item(L.t("撤销", "Undo"), Selector(("undo:")), "z"))
        edit.addItem(item(L.t("重做", "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(L.t("剪切", "Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(L.t("复制", "Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(L.t("粘贴", "Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(L.t("删除", "Delete"), #selector(NSText.delete(_:)), ""))
        edit.addItem(item(L.t("全选", "Select All"), #selector(NSText.selectAll(_:)), "a"))

        let window = submenu(bar, L.t("窗口", "Window"))
        window.addItem(item(L.t("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L.t("缩放", "Zoom"), #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item(L.t("关闭", "Close"), #selector(NSWindow.performClose(_:)), "w"))
        window.addItem(.separator())
        window.addItem(item(L.t("前置全部窗口", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), "", target: NSApp))
        return bar
    }

    /// Sets the main menu; the activation policy stays as it is.
    static func install(settingsTarget: AnyObject?, settingsAction: Selector?) {
        let bar = make(settingsTarget: settingsTarget, settingsAction: settingsAction)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = bar.items.last?.submenu
    }

    private static func submenu(_ bar: NSMenu, _ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        bar.addItem(holder)
        return m
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }
}
