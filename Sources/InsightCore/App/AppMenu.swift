import AppKit

/// A minimal main menu.
///
/// This looks like boilerplate but is not: ⌘X / ⌘C / ⌘V / ⌘A are dispatched through the *Edit menu*
/// of the main menu, not through key bindings. A menu-bar agent (`LSUIElement`) has no main
/// menu, which is why the API key field ignored ⌘V — nothing was wrong with the field.
///
/// The menu bar only becomes visible when the app activates, which happens for the settings
/// window. The result panel never activates, so it stays out of the way.
enum AppMenu {
	static func install() {
		let main = NSMenu(title: "MainMenu")

		// The application menu has to come first even though its title is never shown.
		let appItem = NSMenuItem(title: "Insight", action: nil, keyEquivalent: "")
		let appMenu = NSMenu(title: "Insight")
		appMenu.addItem(
			withTitle: "关于 Insight",
			action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
			keyEquivalent: "")
		appMenu.addItem(.separator())
		appMenu.addItem(
			withTitle: "隐藏 Insight",
			action: #selector(NSApplication.hide(_:)),
			keyEquivalent: "h")
		appMenu.addItem(.separator())
		appMenu.addItem(
			withTitle: "退出 Insight",
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q")
		appItem.submenu = appMenu
		main.addItem(appItem)

		// Selector strings rather than #selector so the actions travel the responder chain and
		// land on whatever text view or field is focused.
		let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
		// `NSSelectorFromString` and not `Selector("…")`. These are responder-chain actions
		// implemented by AppKit (`NSText` and friends), not by anything this project declares, so
		// `#selector` cannot express them. The old `Selector(("…"))` double-parenthesis form was
		// the idiom for silencing the "use #selector" warning; on the current compiler it no
		// longer does, and it produced six warnings that were invisible for as long as nobody
		// forced a rebuild.
		let edit = NSMenu(title: "编辑")
		edit.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
		let redo = NSMenuItem(
			title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
		redo.keyEquivalentModifierMask = [.command, .shift]
		edit.addItem(redo)
		edit.addItem(.separator())
		edit.addItem(withTitle: "剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
		edit.addItem(withTitle: "拷贝", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
		edit.addItem(withTitle: "粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
		let pastePlain = NSMenuItem(
			title: "粘贴并匹配样式", action: NSSelectorFromString("pasteAsPlainText:"),
			keyEquivalent: "V")
		pastePlain.keyEquivalentModifierMask = [.command, .shift]
		edit.addItem(pastePlain)
		edit.addItem(
			withTitle: "删除", action: NSSelectorFromString("delete:"), keyEquivalent: "")
		edit.addItem(
			withTitle: "全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
		editItem.submenu = edit
		main.addItem(editItem)

		// Window management for the settings window.
		let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
		let windowMenu = NSMenu(title: "窗口")
		windowMenu.addItem(
			withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
		windowMenu.addItem(
			withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
		windowMenu.addItem(.separator())
		windowMenu.addItem(
			withTitle: "前置全部窗口",
			action: #selector(NSApplication.arrangeInFront(_:)),
			keyEquivalent: "")
		windowItem.submenu = windowMenu
		main.addItem(windowItem)

		NSApp.mainMenu = main
		NSApp.windowsMenu = windowMenu
	}
}
