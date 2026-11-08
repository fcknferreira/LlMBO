import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!
    static let mainWindowID = NSUserInterfaceItemIdentifier("LlMBOMain")
    private var window: NSWindow?
    /// Altura da barra de título com uma barra de ferramentas vazia: os botões da janela ficam no meio dela.
    static let titlebarHeight: CGFloat = 52
    private var statusItem: StatusItemController?

    private static var termination: DispatchSourceSignal?

    static func main() {
        // Rodado pelo launchd como vigia contra travamento: uma passada e sai, sem interface.
        // Vigia companheiro aberto pelo app: fica em laço até o app terminar (Watchdog.loop).
        if let i = CommandLine.arguments.firstIndex(of: Watchdog.loopArgument) {
            let pid = CommandLine.arguments.indices.contains(i + 1) ? pid_t(CommandLine.arguments[i + 1]) ?? 0 : 0
            Watchdog.loop(appPID: pid)
        }
        if CommandLine.arguments.contains(Watchdog.argument) {
            Watchdog.check()
            exit(0)
        }
        // Rodado por um agente como servidor MCP (stdio): sem interface, até o agente fechar o stdin.
        if CommandLine.arguments.contains(MCPServer.argument) { MCPServer.run() }
        AppLanguage.applyLayoutDirection()   // antes de o NSApplication existir
        Theme.registerFonts()
        // Encerrado à força (kill, logout, desligamento): devolve o repouso antes de sair.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { Engine.shared.shutdown(); Notifier.shared.restoreVolume() }
            exit(0)
        }
        source.resume()
        termination = source
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController()
        _ = Notifier.shared   // registra o delegate cedo (notificação aparece mesmo com o app em primeiro plano)
        if ProcessInfo.processInfo.environment["LLMBO_TEST_NOTIFY"] != nil { Notifier.shared.selfTest() }
        // A janela abre junto com o app, para ele não ficar "invisível"
        // (o ícone da barra de menus pode ficar escondido atrás do notch ou do Bartender).
        // Aberto por uma atualização automática: fica só na barra de menus e avisa (não abre a janela no meio
        // do que a pessoa estiver fazendo).
        WhatsNew.prepare()
        let autoUpdated = Updater.consumeAutoMarker()
        if OnboardingModel.needed { showOnboarding() } else if !autoUpdated { showMainWindow() }
        if autoUpdated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Notifier.shared.updated(to: Project.version) }
        }
        AppLog.write("aberto: LlMBO \(Project.version) (\(Project.build)) em \(AppLog.redact(Bundle.main.bundlePath))")
        Updater.shared.start()
        if ProcessInfo.processInfo.environment["LLMBO_TEST_UPDATE"] != nil {
            Task { await Updater.shared.check(); await Updater.shared.install() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MoveToApplications.offerIfNeeded() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_HOOKS"] != nil { Hooks.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_QUOTA"] != nil { Engine.quotaSelfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_MCP"] != nil { MCPInstall.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_UNINSTALL"] != nil { Uninstaller.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_USAGE"] != nil { TokenScanner.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_CODEX"] != nil { CodexResume.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_AGRESUME"] != nil { AntigravityResume.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_BACKGROUND"] != nil { ClaudeBackground.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_SLEEPGUARD"] != nil { Power.SleepGuard.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_WIDGET"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { WidgetFeed.selfTest(Engine.shared) }
        }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_AGQUOTA"] != nil { AntigravityQuota.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_CLAUDEUSAGE"] != nil { ClaudeUsageCLI.selfTest() }
        if ProcessInfo.processInfo.environment["LLMBO_TEST_TABCLICK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Diagnostics.clickTab() }
        }
        if ProcessInfo.processInfo.environment["LLMBO_DIAG"] != nil {
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in Diagnostics.write() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nunca deixa o Mac preso sem dormir ao sair.
        Engine.shared.shutdown()
        Notifier.shared.restoreVolume()   // som da tampa no meio: devolve o volume do Mac
    }

    private var onboarding: NSWindow?

    /// Assistente da primeira abertura (também reaberto pela aba Geral).
    func showOnboarding() {
        closeMenu()
        if onboarding == nil {
            let model = OnboardingModel()
            let host = NSHostingController(rootView: OnboardingView(model: model).environmentObject(Engine.shared))
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Configurar o LlMBO")
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            Theme.style(w)
            w.isReleasedWhenClosed = false
            w.center()
            model.finish = { [weak self, weak w] in
                UserDefaults.standard.set(true, forKey: OnboardingModel.doneKey)
                w?.close()
                self?.onboarding = nil
                self?.showMainWindow()
            }
            onboarding = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }

    func closeMenu() { statusItem?.closeMenu() }
    var statusItemDebug: String { statusItem?.diagnosticLine ?? "statusItem=nil" }

    @objc func showPreferencesWindow(_ sender: Any?) {
        showMainWindow()
    }

    func showMainWindow() {
        closeMenu()
        if window == nil {
            let host = NSHostingController(rootView: MainWindowView().environmentObject(Engine.shared))
            // A altura muda com a aba e com o conteúdo: o AppKit ajusta a janela pela preferredContentSize,
            // mantendo o topo no lugar.
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.identifier = Self.mainWindowID
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            Theme.style(w)
            // Barra de ferramentas vazia só para a barra de título ganhar altura e alinhar os botões
            // da janela com as abas (que são SwiftUI, por baixo da barra transparente).
            let toolbar = NSToolbar(identifier: "LlMBOMain")
            toolbar.showsBaselineSeparator = false
            w.toolbar = toolbar
            w.toolbarStyle = .unified
            w.title = String(localized: "LlMBO")
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: TabFrame.width, height: 560))
            w.center()
            w.setFrameAutosaveName("LlMBOMain")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Com LLMBO_DIAG=1, grava em launch.log as janelas do app (inclusive a do ícone da barra).
enum Diagnostics {
    @MainActor private static var tabsChecked = false
    @MainActor static func write() {
        var lines = ["LlMBO \(Date())"]
        for w in NSApp.windows {
            lines.append("\(type(of: w)) id=\(w.identifier?.rawValue ?? "-") vc=\(w.contentViewController.map { "\(type(of: $0))" } ?? "-") visível=\(w.isVisible) frame=\(NSStringFromRect(w.frame)) tela=\(w.screen?.localizedName ?? "nenhuma") título=\(w.title)")
        }
        lines.append(AppDelegate.shared.statusItemDebug)
        lines += Engine.shared.watcherDiagnostics
        for st in Engine.shared.statuses {
            lines.append("agente \(st.id): rodando=\(st.running) ativo=\(st.active) motivo=\(st.reason ?? "-") cpu=\(st.cpu) hook=\(st.hook)")
        }
        lines.append("lista: " + Engine.shared.agents.map(\.name).joined(separator: ", "))
        for g in AddAgentMenu.groups(available: Engine.shared.availableCatalog) {
            lines.append("menu \(g.title): " + g.agents.map(\.name).joined(separator: ", "))
        }
        // Altura e título reais da janela em cada aba, lidos 0,8 s depois da troca (fim da animação);
        // grava em tabs.log e volta para a aba que estava aberta.
        if !tabsChecked, let main = NSApp.windows.first(where: { $0.identifier == AppDelegate.mainWindowID }) {
            tabsChecked = true
            let model = MainTabModel.shared
            let original = model.tab
            var out: [String] = []
            func step(_ i: Int) {
                guard i < SettingsTab.allCases.count else {
                    model.tab = original
                    try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("tabs.log"),
                                                           atomically: true, encoding: .utf8)
                    return
                }
                model.tab = SettingsTab.allCases[i]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    out.append("aba \(SettingsTab.allCases[i].title): janela \(Int(main.frame.height)) pt, topo \(Int(main.frame.maxY))")
                    step(i + 1)
                }
            }
            step(0)
        }
        let url = Paths.support.appendingPathComponent("launch.log")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        // Retratos da janela, de cada aba e do popover, para revisar o visual sem gravação de tela.
        if let main = NSApp.windows.first(where: { $0.identifier == AppDelegate.mainWindowID }),
           let v = main.contentView?.superview {
            snapshot(v, to: "window.png")
        }
        for tab in SettingsTab.allCases {
            let v = NSHostingView(rootView: tab.view.environmentObject(Engine.shared)
                .background(Theme.bg).preferredColorScheme(.dark))
            v.frame.size = v.fittingSize
            let holder = NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.appearance = Theme.appearance
            holder.contentView = v
            snapshot(v, to: "tab-\(tab.rawValue).png")
        }
        for step in OnboardingStep.allCases {
            let model = OnboardingModel()
            model.step = step
            let v = NSHostingView(rootView: OnboardingView(model: model).environmentObject(Engine.shared)
                .background(Theme.bg).preferredColorScheme(.dark))
            v.frame.size = v.fittingSize
            let holder = NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.appearance = Theme.appearance
            holder.contentView = v
            snapshot(v, to: "onboarding-\(step.rawValue).png")
        }
        if let sample = Engine.shared.agents.first(where: { $0.id == "ollama" }) ?? Engine.shared.agents.first {
            let model = AgentsTabModel()
            let v = NSHostingView(rootView: AgentEditor(draft: AgentDraft(sample), model: model)
                .environmentObject(Engine.shared).background(Theme.bg).preferredColorScheme(.dark))
            v.frame.size = v.fittingSize
            let holder = NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.appearance = Theme.appearance
            holder.contentView = v
            snapshot(v, to: "editor.png")
        }
        let e = Engine.shared
        let lists: [(String, AnyView)] = [
            ("dropdown-idioma.png", AnyView(DropdownList(groups: [DropdownGroup(items: AppLanguage.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                                                          selection: e.language, width: 230, footer: nil) { _ in })),
            ("dropdown-agentes.png", AnyView(DropdownList(groups: AddAgentMenu.groups(available: e.availableCatalog).map { g in
                DropdownGroup(title: g.title, items: g.agents.map { DropdownItem(id: $0.id, title: $0.name) }) },
                                                          selection: nil, width: 270,
                                                          footer: DropdownFooter(title: String(localized: "Outro agente (personalizado)…"), symbol: "plus") {}) { _ in })),
            ("dropdown-temperatura.png", AnyView(DropdownList(groups: [DropdownGroup(items: ThermalLimit.allCases.map { DropdownItem(id: $0, title: $0.title) })],
                                                              selection: e.thermalLimit, width: 220, footer: nil) { _ in })),
        ]
        for (name, list) in lists {
            let v = NSHostingView(rootView: list)
            v.frame.size = v.fittingSize
            let holder = NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.appearance = Theme.appearance
            holder.contentView = v
            snapshot(v, to: name)
        }
        let popover = NSHostingView(rootView: MenuView().environmentObject(Engine.shared)
            .background(Theme.bg2).preferredColorScheme(.dark))
        popover.frame.size = popover.fittingSize
        let holder = NSWindow(contentRect: popover.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.appearance = Theme.appearance
        holder.contentView = popover
        popover.layoutSubtreeIfNeeded()
        snapshot(popover, to: "popover.png")
    }

    /// LLMBO_TEST_TABCLICK=1: clica de verdade (eventos de mouse pela janela) na aba "Sobre", que fica na
    /// faixa da barra de título, e grava em tabclick.log se a aba mudou.
    @MainActor static func clickTab() {
        guard let w = NSApp.windows.first(where: { $0.identifier == AppDelegate.mainWindowID }) else { return }
        MainTabModel.shared.tab = .general
        let before = MainTabModel.shared.tab
        // "Sobre" é a última pílula: ~45 pt da borda direita, no meio da faixa da barra de título.
        let p = NSPoint(x: w.frame.width - 45, y: w.frame.height - AppDelegate.titlebarHeight / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                w.sendEvent(e)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let line = "antes=\(before) depois=\(MainTabModel.shared.tab) ponto=\(p)\n"
            try? line.write(to: Paths.support.appendingPathComponent("tabclick.log"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor private static func snapshot(_ view: NSView, to name: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: Paths.support.appendingPathComponent(name))
    }
}
