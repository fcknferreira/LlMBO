import AppKit
import Combine
import SwiftUI

/// Ícone da barra de menus. Clique esquerdo liga/desliga a tampa fechada; clique direito (ou Control-clique)
/// abre o menu — ou o inverso, com "Inverter os cliques do ícone" (aba Geral, `Engine.swapStatusClicks`). O MenuBarExtra do SwiftUI não distingue os dois cliques, por isso é um NSStatusItem.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var armedWatch: AnyCancellable?
    private var swapWatch: AnyCancellable?
    /// Enquanto o menu está aberto: cliques em outros apps/na mesa (global) e nas outras janelas do LlMBO (local).
    private var outsideClickMonitors: [Any] = []

    override init() {
        super.init()
        let host = NSHostingController(rootView: MenuView().environmentObject(Engine.shared))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        // Fechar é por nossa conta (monitores de clique): o .transient só percebe cliques dentro do app ativo,
        // e o app não é ativado ao abrir o menu (ativar traria a janela de configurações junto).
        popover.behavior = .applicationDefined
        popover.appearance = Theme.appearance
        popover.delegate = self

        // Sem autosaveName próprio: fica "Item-0", o mesmo nome do ícone das versões anteriores, então a posição
        // e as regras do Bartender (que pode escondê-lo) continuam valendo.
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        swapWatch = Engine.shared.$swapStatusClicks.sink { [weak self] swapped in
            self?.item.button?.toolTip = swapped
                ? String(localized: "Clique: menu · Clique direito: liga/desliga a tampa fechada")
                : String(localized: "Clique: liga/desliga a tampa fechada · Clique direito: menu")
        }
        // O ícone acompanha o estado: parado ou com o disco (Mac acordado esperando os agentes).
        armedWatch = Engine.shared.$armed.sink { [weak self] armed in
            self?.item.button?.image = BlackHoleIcon.image(active: armed)
            self?.item.button?.setAccessibilityLabel(armed
                ? String(localized: "LlMBO: tampa fechada liberada")
                : String(localized: "LlMBO: repouso normal"))
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        let engine = Engine.shared
        let wantsMenu = engine.swapStatusClicks ? !secondary : secondary
        // Sem a permissão não dá para ligar: qualquer clique abre o menu, que mostra como instalar.
        if wantsMenu || !engine.helperInstalled {
            toggleMenu(sender)
        } else {
            closeMenu()
            engine.armed ? engine.disarm() : engine.arm()
        }
    }

    private func toggleMenu(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closeMenu()
        } else {
            // Sem NSApp.activate: ativar o app traz todas as janelas dele para a frente.
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            watchOutsideClicks()
        }
    }

    /// Qualquer clique fora do menu fecha o menu. Cliques no próprio ícone ficam com `clicked`, que alterna.
    private func watchOutsideClicks() {
        stopWatching()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.closeMenu() }
        }) { outsideClickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            let inMenu = event.window === self.popover.contentViewController?.view.window
            let onIcon = event.window === self.item.button?.window
            if !inMenu && !onIcon { self.closeMenu() }
            return event
        }) { outsideClickMonitors.append(local) }
    }

    private func stopWatching() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.stopWatching() }
    }

    /// Para o diagnóstico.
    var diagnosticLine: String {
        let b = item.button
        return "statusItem visível=\(item.isVisible) autosave=\(item.autosaveName ?? "-") imagem=\(b?.image != nil) "
            + "botão=\(b.map { NSStringFromRect($0.frame) } ?? "-") janela=\(b?.window.map { NSStringFromRect($0.frame) } ?? "-")"
    }

    func closeMenu() {
        if popover.isShown { popover.performClose(nil) }
    }
}
