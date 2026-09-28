import SwiftUI

struct SpaceAppearance: Codable, Equatable {
    var light: String
    var dark: String
    var strength: Double

    func tint(darkMode: Bool) -> String {
        darkMode && dark != Tint.same ? dark : light
    }
}

extension Browser {
    var globalAppearance: SpaceAppearance {
        SpaceAppearance(light: prefs.chromeTint, dark: prefs.chromeTintDark, strength: prefs.chromeTintStrength)
    }

    func appearance(for id: UUID?) -> SpaceAppearance {
        spaces.first(where: { $0.id == id })?.appearance ?? globalAppearance
    }

    var effectiveAppearance: SpaceAppearance {
        appearance(for: spaceID)
    }

    func setAppearance(_ value: SpaceAppearance?, for id: UUID) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].appearance = value
        Spaces.write(spaces)
    }

    func editAppearance(_ id: UUID?, _ edit: (inout SpaceAppearance) -> Void) {
        var value = appearance(for: id)
        edit(&value)
        if let id {
            setAppearance(value, for: id)
        } else {
            if prefs.chromeTint != value.light { prefs.chromeTint = value.light }
            if prefs.chromeTintDark != value.dark { prefs.chromeTintDark = value.dark }
            if prefs.chromeTintStrength != value.strength { prefs.chromeTintStrength = value.strength }
        }
    }

    func clearSpaceTransition() {
        spaceTransitionTicket = UUID()
        spaceTransitionTarget = nil
        spaceCapturing = false
        spaceTintFrom = nil
        spaceTintTo = nil
        spaceTintProgress = 1
        spacePageImage = nil
        spacePageOpacity = 0
        rowShift = 0
        rowFade = 1
        rowScale = 1
    }

    func prepareSpaceTransition(to id: UUID, replacing: Bool = false) {
        guard replacing || spaceTransitionTarget != id else { return }
        clearSpaceTransition()
        guard !Motion.reduced, window != nil, spaces.contains(where: { $0.id == id }) else { return }
        spaceTransitionTarget = id
        spaceTintFrom = effectiveAppearance
        spaceTintTo = appearance(for: id)
        spaceTintProgress = 0
        // Only the page already visible. No wait, disk encoding, or background-tab captures.
        guard let tab = active, let web = tab.built, web.window === window,
              !tab.noisy, !Players.knows(tab.address), floating == nil, systemPiP == nil,
              shownSplit == nil, splitPicking == nil, !tab.isBlank else { return }
        let ticket = spaceTransitionTicket
        let address = tab.address
        spaceCapturing = true
        tab.preview(width: min(web.bounds.width, 1440)) { [weak self, weak tab] image in
            guard let self, self.spaceTransitionTicket == ticket, self.spaceCapturing,
                  tab?.address == address, let image else { return }
            self.spacePageImage = image
            self.spacePageOpacity = 1
        }
    }

    func animateSpaceSwitch(_ change: @escaping () -> Void) {
        guard spaceTransitionTarget != nil else { return }
        let ticket = spaceTransitionTicket
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            spaceSwipe = 0
            nameSwipe = 0
        }
        withAnimation(.easeOut(duration: 0.16), completionCriteria: .removed) {
            spaceSwipe = -CGFloat(spaceStep) * (prefs.sidebar ? prefs.sideWidth : Metrics.strip)
            spaceTintProgress = 1
        } completion: {
            guard ticket == self.spaceTransitionTicket else { return }
            guard let target = self.spaceTransitionTarget, self.spaces.contains(where: { $0.id == target }) else {
                self.clearSpaceTransition()
                return
            }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                change()
                self.spaceSwipe = 0
                self.rowShift = 0
                self.rowFade = 1
            }
            self.finishSpaceTransition(ticket)
        }
    }

    func finishSpaceTransition(_ ticket: UUID) {
        guard ticket == spaceTransitionTicket else { return }
        spaceCapturing = false
        withAnimation(Motion.reduced ? nil : .easeOut(duration: 0.08), completionCriteria: .removed) {
            spacePageOpacity = 0
            rowFade = 1
        } completion: {
            guard ticket == self.spaceTransitionTicket else { return }
            self.clearSpaceTransition()
        }
    }
}

/// The same swatches and persistence as Settings, beside the Space menu.
struct SpaceAppearancePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    private var appearance: SpaceAppearance { browser.appearance(for: browser.spaceID) }
    private var inherited: Bool { browser.space.appearance == nil }

    private func tint<Value>(_ key: WritableKeyPath<SpaceAppearance, Value>) -> Binding<Value> {
        Binding(get: { browser.appearance(for: browser.spaceID)[keyPath: key] }, set: { value in
            browser.editAppearance(browser.spaceID) { $0[keyPath: key] = value }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(browser.space.name) appearance")
                .font(.headline)
                .lineLimit(1)
            Toggle("Use global appearance", isOn: Binding(get: { inherited }, set: { inherit in
                browser.setAppearance(inherit ? nil : browser.globalAppearance, for: browser.spaceID)
            }))
            .toggleStyle(.switch)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Light tint").font(.subheadline)
                TintPicker(hex: tint(\.light))
                Text("Dark tint").font(.subheadline)
                TintPicker(hex: tint(\.dark), offersSame: true)
                if !appearance.light.isEmpty || !["", Tint.same].contains(appearance.dark) {
                    Text("Tint strength").font(.subheadline)
                    Slider(value: tint(\.strength), in: Tint.strengths)
                }
            }
            .disabled(inherited)
        }
        .frame(width: 340)
        .padding(16)
    }
}
