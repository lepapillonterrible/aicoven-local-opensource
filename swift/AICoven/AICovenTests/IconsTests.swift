@testable import AICoven
import GRDB
import XCTest

/// A coven has an icon and an agent a face: a symbol on one of twelve
/// tints, as the cloud app draws them, kept with their settings.
final class IconsTests: XCTestCase {

    // MARK: - Tints, symbols

    func testTheTwelveTints() {
        XCTAssertEqual(IconTint.allCases.map(\.rawValue), ["warm", "water", "rust", "ink", "moss", "sky", "lilac", "rose", "mint", "pine", "slate", "plum"])
        XCTAssertEqual(IconTint.allCases.map(\.label), ["Sand", "Water", "Clay", "Ink", "Moss", "Sky", "Lilac", "Rose", "Mint", "Pine", "Slate", "Plum"])
        XCTAssertEqual(IconTint.nextUnused(worn: []), .warm)
        XCTAssertEqual(IconTint.nextUnused(worn: ["warm", nil, "rust", "no-such-tint"]), .water)
        XCTAssertEqual(IconTint.nextUnused(worn: IconTint.allCases.map(\.rawValue)), .warm, "When every one is worn, the first")
        XCTAssertNil(IconTint(rawValue: "teal"))
    }

    func testWhatMayBeASymbolsName() {
        for name in ["house", "chart.bar.xaxis", "building.2", "0.circle.fill", String(repeating: "a", count: 64)] {
            XCTAssertTrue(IconRules.isSymbolName(name), name)
        }
        for name in ["", "House", "house fill", "house/..", "🏠", "a\nb", String(repeating: "a", count: 65)] {
            XCTAssertFalse(IconRules.isSymbolName(name), name)
        }
    }

    func testTheSymbolAnAgentsEmojiStandsFor() {
        XCTAssertEqual(AgentFace.suggestedSymbols.count, 16)
        XCTAssertEqual(CovenIcon.suggestedSymbols.count, 16)
        XCTAssertEqual(AgentFace.symbol(forEmoji: "🤖"), "cpu")
        XCTAssertEqual(AgentFace.symbol(forEmoji: "🧠"), "brain")
        XCTAssertEqual(AgentFace.symbol(forEmoji: "⚙️"), "gearshape", "With or without its variation selector")
        XCTAssertEqual(AgentFace.symbol(forEmoji: "⚙"), "gearshape")
        XCTAssertEqual(AgentFace.symbol(forEmoji: "✍️"), "pencil")
        XCTAssertEqual(AgentFace.symbol(forEmoji: "💻"), "laptopcomputer")
        // Every emoji the app offered for an agent stands for a symbol.
        for emoji in ["🤖", "🧠", "💡", "🎨", "📝", "🔍", "⚙️", "📊", "🚀", "💬", "🎯", "🔬", "📚", "✨", "🌟", "🎭"] {
            XCTAssertNotNil(AgentFace.symbol(forEmoji: emoji), emoji)
        }
        XCTAssertEqual(AgentFace.symbol(forEmoji: "🌟"), "star")
        // The symbols they stand for are the cloud app's suggested ones, in the order the emoji were offered.
        XCTAssertEqual(
            ["🤖", "🧠", "💡", "🎨", "📝", "🔍", "⚙️", "📊", "🚀", "💬", "🎯", "🔬", "📚", "✨", "🌟", "🎭"].map { AgentFace.symbol(forEmoji: $0) },
            AgentFace.suggestedSymbols
        )
        XCTAssertNil(AgentFace.symbol(forEmoji: "🦄"))
        XCTAssertNil(AgentFace.symbol(forEmoji: nil))
        // Every symbol an emoji stands for, and every suggested one, can be a stored symbol.
        for emoji in ["🤖", "🧠", "💡", "🎨", "📝", "🔍", "⚙️", "📊", "🚀", "💬", "🎯", "🔬", "📚", "✨", "💻", "✍️", "🎓"] {
            let symbol = AgentFace.symbol(forEmoji: emoji)
            XCTAssertEqual(symbol.map(IconRules.isSymbolName), true, emoji)
        }
        for symbol in AgentFace.suggestedSymbols + CovenIcon.suggestedSymbols {
            XCTAssertTrue(IconRules.isSymbolName(symbol), symbol)
        }
    }

    @MainActor
    func testASymbolThisSystemCannotDrawIsReplaced() {
        XCTAssertEqual(SymbolDisc.renderable("house", fallback: "cpu"), "house")
        XCTAssertEqual(SymbolDisc.renderable("no.such.symbol.anywhere", fallback: "cpu"), "cpu")
        for symbol in AgentFace.suggestedSymbols + CovenIcon.suggestedSymbols + ["scope", "laptopcomputer", "graduationcap", "doc.text"] {
            XCTAssertTrue(SymbolDisc.isRenderable(symbol), "\(symbol) can be drawn on this system")
        }
    }

    func testTheSymbolsThePickerSearches() {
        let catalog = SymbolCatalog(symbols: [["pencil", "write draw edit"], ["pencil.circle"], ["square.and.pencil", "compose"], ["house", "home building"], []])
        XCTAssertEqual(catalog.count, 4)
        XCTAssertEqual(catalog.search("pencil"), ["pencil", "pencil.circle", "square.and.pencil"])
        XCTAssertEqual(catalog.search(" WRITE "), ["pencil"], "By its keywords, whatever the case")
        XCTAssertEqual(catalog.search("home"), ["house"])
        XCTAssertEqual(catalog.search(""), [])
        XCTAssertEqual(catalog.search("zzz"), [])
        let many = SymbolCatalog(symbols: (0 ..< 300).map { ["symbol.\($0)"] })
        XCTAssertEqual(many.search("symbol").count, SymbolCatalog.resultLimit)

        // The list that comes with the app is there and is read.
        XCTAssertGreaterThan(SymbolCatalog.shared.count, 4000)
        XCTAssertTrue(SymbolCatalog.shared.search("write").contains("pencil"))
    }

    // MARK: - As stored

    private func coven(_ id: String, settings: CovenSettings?) -> Coven {
        Coven(id: id, name: id, settings: settings, createdAt: Date(), updatedAt: Date())
    }

    func testACovensIcon_isReadFromItsSettings() throws {
        let stored = try JSONDecoder().decode(CovenSettings.self, from: Data(#"{"icon_symbol": "leaf", "icon_tint": "moss", "connections": {"apps": {}, "mcp_servers": {}}}"#.utf8))
        XCTAssertEqual(stored.iconSymbol, "leaf")
        XCTAssertEqual(stored.iconTint, "moss")
        let leaf = coven("a", settings: stored)
        XCTAssertEqual(leaf.iconSymbol, "leaf")
        XCTAssertEqual(leaf.iconTintValue, .moss)

        // None stored, or one that is no symbol or no tint: the default is shown.
        XCTAssertNil(coven("b", settings: nil).iconSymbol)
        XCTAssertNil(coven("b", settings: nil).iconTintValue)
        let odd = coven("c", settings: CovenSettings(iconSymbol: "../etc", iconTint: "teal"))
        XCTAssertNil(odd.iconSymbol)
        XCTAssertNil(odd.iconTintValue)
        // An icon stored as something else does not hide the other settings.
        let unreadable = try JSONDecoder().decode(CovenSettings.self, from: Data(#"{"icon_symbol": 3, "icon_tint": ["moss"], "budget_caps": {"monthly": 5}}"#.utf8))
        XCTAssertNil(unreadable.iconSymbol)
        XCTAssertNil(unreadable.iconTint)
        XCTAssertEqual(unreadable.budgetCaps, ["monthly": 5])
        // It is written under the cloud app's names.
        let written = try String(decoding: JSONEncoder().encode(CovenSettings(iconSymbol: "leaf", iconTint: "moss")), as: UTF8.self)
        XCTAssertTrue(written.contains(#""icon_symbol":"leaf""#) && written.contains(#""icon_tint":"moss""#), written)
    }

    @MainActor
    func testTheNameANewCovenIsMadeWith() {
        XCTAssertEqual(NewCovenForm.name(from: "  Work \n"), "Work", "Without the space around it")
        XCTAssertNil(NewCovenForm.name(from: ""), "None")
        XCTAssertNil(NewCovenForm.name(from: "  \n\t "), "Space alone is no name")
        XCTAssertEqual(NewCovenForm.name(from: "Side  project"), "Side  project", "What is inside it is the person's")
        let long = String(repeating: "a", count: 99) + " bcd"
        XCTAssertEqual(NewCovenForm.name(from: long), String(repeating: "a", count: 99), "Cut at the longest, and not left ending in a space")
        XCTAssertEqual(NewCovenForm.name(from: String(repeating: "é", count: 150))?.count, NewCovenForm.longestName)
    }

    func testANewCovenStartsWithAnIconNoOtherShows() {
        XCTAssertEqual(CovenIcon.startingIcon(among: []).symbol, "house")
        XCTAssertEqual(CovenIcon.startingIcon(among: []).tint, .warm)
        // One made before covens had icons shows a house on sand.
        let old = coven("old", settings: nil)
        let second = CovenIcon.startingIcon(among: [old])
        XCTAssertEqual(second.symbol, "briefcase")
        XCTAssertEqual(second.tint, .water)
        let third = CovenIcon.startingIcon(among: [old, coven("b", settings: CovenSettings(iconSymbol: "briefcase", iconTint: "water"))])
        XCTAssertEqual(third.symbol, "book.closed")
        XCTAssertEqual(third.tint, .rust)
        // What counts is what a coven shows: a stored symbol this system
        // cannot draw, or that is no symbol's name, shows a house.
        let undrawable = coven("u", settings: CovenSettings(iconSymbol: "no.such.symbol.anywhere", iconTint: "teal"))
        XCTAssertEqual(CovenIcon.startingIcon(among: [undrawable]).symbol, "briefcase", "A house is shown already")
        XCTAssertEqual(CovenIcon.startingIcon(among: [undrawable]).tint, .water, "And sand is worn")
        XCTAssertEqual(CovenIcon.startingIcon(amongIcons: [("Not A Symbol", nil), ("briefcase", "water")]).symbol, "book.closed")
        // When every symbol and tint is shown, the first of each.
        let all = zip(CovenIcon.suggestedSymbols, IconTint.allCases + IconTint.allCases).map { symbol, tint in
            coven(symbol, settings: CovenSettings(iconSymbol: symbol, iconTint: tint.rawValue))
        }
        XCTAssertEqual(CovenIcon.startingIcon(among: all).symbol, "house")
        XCTAssertEqual(CovenIcon.startingIcon(among: all).tint, .warm)
    }

    private func role(emoji: String?, settings: RoleSettings?) -> Role {
        Role(id: "r", covenId: "c", name: "Agent", emoji: emoji, description: nil, systemPrompt: nil, model: nil, provider: "openai", providerAccountId: nil, temperature: nil, maxTokens: nil, settings: settings, createdAt: Date(), updatedAt: Date())
    }

    func testAnAgentsFace_isItsStoredSymbol_orTheOneItsEmojiStandsFor() throws {
        XCTAssertEqual(role(emoji: "🧠", settings: RoleSettings(iconSymbol: "star", iconTint: "plum")).iconSymbol, "star")
        XCTAssertEqual(role(emoji: "🧠", settings: RoleSettings(iconSymbol: "star", iconTint: "plum")).iconTintValue, .plum)
        XCTAssertEqual(role(emoji: "🧠", settings: nil).iconSymbol, "brain", "An agent made when agents had an emoji")
        XCTAssertEqual(role(emoji: "🧠", settings: RoleSettings(iconSymbol: "Not A Symbol")).iconSymbol, "brain")
        XCTAssertNil(role(emoji: "🦄", settings: nil).iconSymbol, "The face then shows cpu")
        XCTAssertNil(role(emoji: nil, settings: RoleSettings(iconTint: "teal")).iconTintValue)

        let stored = try JSONDecoder().decode(RoleSettings.self, from: Data(#"{"icon_symbol": "map", "icon_tint": "sky", "autonomous_mode": true}"#.utf8))
        XCTAssertEqual(stored.iconSymbol, "map")
        XCTAssertEqual(stored.iconTint, "sky")
        XCTAssertEqual(stored.autonomousMode, true)
        let unreadable = try JSONDecoder().decode(RoleSettings.self, from: Data(#"{"icon_symbol": {}, "autonomous_max_steps": 4}"#.utf8))
        XCTAssertNil(unreadable.iconSymbol)
        XCTAssertEqual(unreadable.autonomousMaxSteps, 4)
    }

    func testACovenIsMadeForTheAccountThatAsked_whoeverIsSignedInWhenItIsStored() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        // The account that asked, noted as it asked; another is signed in by the time the coven is stored.
        let asked = "asked-\(UUID().uuidString)"
        let coven = try await CovenService.shared.createCoven(name: "Owned \(UUID().uuidString)", as: asked)
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
            await DataEncryptionService.shared.lock()
        }

        let ofTheSignedIn = try await CovenService.shared.loadCovens()
        XCTAssertFalse(ofTheSignedIn.contains { $0.id == coven.id }, "It is not the signed-in account's")
        let itsOwners = try await CovenRepository.shared.connections(ofCoven: coven.id, for: asked)
        XCTAssertEqual(itsOwners, CovenConnections(), "It is the account's that asked")
        let signedIn = await MainActor.run { UserScope.currentUserID }
        do {
            _ = try await CovenRepository.shared.connections(ofCoven: coven.id, for: signedIn)
            XCTFail("The signed-in account was given another's coven")
        } catch CovenRepositoryError.covenNotFound {}
    }

    func testAnAgentIsReadOnlyByItsOwnAccount() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        let coven = try await CovenService.shared.createCoven(name: "Agents \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
            await DataEncryptionService.shared.lock()
        }
        let mine = try await RoleService.shared.createRole(covenId: coven.id, name: "Mine", systemPrompt: "Answer briefly.")
        let read = try await RoleService.shared.getRole(roleId: mine.id)
        XCTAssertEqual(read.systemPrompt, "Answer briefly.")

        // The same agent, once it and its coven are another account's: its id is known, and it is not found.
        let store = try await MainActor.run { try XCTUnwrap(DatabaseManager.shared.dbQueue) }
        let another = "another-\(UUID().uuidString)"
        try await store.write { db in
            try db.execute(sql: "UPDATE covens SET user_id = ? WHERE id = ?", arguments: [another, coven.id])
            try db.execute(sql: "UPDATE roles SET user_id = ? WHERE id = ?", arguments: [another, mine.id])
        }
        do {
            _ = try await RoleService.shared.getRole(roleId: mine.id)
            XCTFail("Another account's agent was read")
        } catch CovenRepositoryError.roleNotFound {}
    }

    // MARK: - Kept on the device

    func testIconsAreKeptWithTheirCovenAndAgent_andWhatElseIsStoredStays() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        let first = try await CovenService.shared.createCoven(name: "Icons \(UUID().uuidString)")
        let chosen = try await CovenService.shared.createCoven(name: "Icons \(UUID().uuidString)", icon: ("leaf", .moss))
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: first.id)
            try? await CovenService.shared.deleteCoven(id: chosen.id)
            await DataEncryptionService.shared.lock()
        }

        // A coven made without one starts with an icon; one made with one has it.
        XCTAssertNotNil(first.iconSymbol)
        XCTAssertNotNil(first.iconTintValue)
        XCTAssertEqual(chosen.iconSymbol, "leaf")
        XCTAssertEqual(chosen.iconTintValue, .moss)
        XCTAssertEqual(chosen.settings?.connections, CovenConnections(), "It still starts with nothing connected")

        // Changing the icon keeps the coven's other settings.
        try await CovenService.shared.setConnections(CovenConnections(apps: ["github": .readOnly]), forCoven: first.id)
        try await CovenService.shared.setIcon(symbol: "flask", tint: .sky, forCoven: first.id)
        var stored = try await CovenService.shared.loadCovens().first { $0.id == first.id }
        XCTAssertEqual(stored?.iconSymbol, "flask")
        XCTAssertEqual(stored?.iconTintValue, .sky)
        XCTAssertEqual(stored?.settings?.connections, CovenConnections(apps: ["github": .readOnly]))
        // And changing the connections keeps the icon.
        try await CovenService.shared.setConnections(CovenConnections(), forCoven: first.id)
        stored = try await CovenService.shared.loadCovens().first { $0.id == first.id }
        XCTAssertEqual(stored?.iconSymbol, "flask")
        // What cannot be a symbol is not stored, and is said to be that.
        do {
            try await CovenService.shared.setIcon(symbol: "Not A Symbol", tint: .sky, forCoven: first.id)
            XCTFail("Stored what is no symbol")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That is not a symbol's name")
        }
        do {
            _ = try await CovenService.shared.createCoven(name: "No", icon: ("Not A Symbol", .sky))
            XCTFail("Made a coven with what is no symbol")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That is not a symbol's name")
        }
        // Covens made at once do not start with the same icon, while
        // there is a symbol and a tint none shows.
        let before = try await CovenService.shared.loadCovens()
        async let one = CovenService.shared.createCoven(name: "At once \(UUID().uuidString)")
        async let two = CovenService.shared.createCoven(name: "At once \(UUID().uuidString)")
        let together = try await [one, two]
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            for coven in together {
                try? await CovenService.shared.deleteCoven(id: coven.id)
            }
        }
        if before.count + 2 <= IconTint.allCases.count {
            XCTAssertNotEqual(together[0].settings?.iconSymbol, together[1].settings?.iconSymbol)
            XCTAssertNotEqual(together[0].settings?.iconTint, together[1].settings?.iconTint)
        }

        // An agent starts with a face: its emoji's symbol, on a tint no other agent of the coven wears.
        let writer = try await RoleService.shared.createRole(covenId: first.id, name: "Writer", emoji: "✍️")
        let coder = try await RoleService.shared.createRole(covenId: first.id, name: "Coder", emoji: "💻", autonomousMode: true)
        XCTAssertEqual(writer.iconSymbol, "pencil")
        XCTAssertEqual(writer.iconTintValue, .warm)
        XCTAssertEqual(coder.iconSymbol, "laptopcomputer")
        XCTAssertEqual(coder.iconTintValue, .water)
        XCTAssertEqual(coder.settings?.autonomousMode, true)

        // Its face is changed, and stays when the form saves its other settings.
        try await RoleService.shared.setIcon(symbol: "star", tint: .plum, forRole: coder.id)
        let saved = try await RoleService.shared.updateRole(roleId: coder.id, name: "Coder 2", autonomousMode: false, autonomousMaxSteps: 3)
        XCTAssertEqual(saved.name, "Coder 2")
        XCTAssertEqual(saved.iconSymbol, "star")
        XCTAssertEqual(saved.iconTintValue, .plum)
        XCTAssertEqual(saved.settings?.autonomousMode, false)
        XCTAssertEqual(saved.settings?.autonomousMaxSteps, 3)
        XCTAssertEqual(saved.emoji, "💻", "Its emoji stays as it was stored")

        // One made with a face chosen for it has that face.
        let designer = try await RoleService.shared.createRole(covenId: first.id, name: "Designer", icon: ("paintpalette", .rose))
        XCTAssertEqual(designer.iconSymbol, "paintpalette")
        XCTAssertEqual(designer.iconTintValue, .rose)
        // An agent is not made in a coven that is not the person's.
        do {
            _ = try await RoleService.shared.createRole(covenId: "no-such-coven-\(UUID().uuidString)", name: "Stray")
            XCTFail("Made an agent in no coven of the person's")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Coven not found")
        }

        // The tints worn are those the agents show: one whose settings do
        // not read as settings shows sand, whatever tint is written in them.
        let fresh = try await CovenService.shared.createCoven(name: "Icons \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: fresh.id)
        }
        let odd = try await RoleService.shared.createRole(covenId: fresh.id, name: "Odd")
        XCTAssertEqual(odd.iconTintValue, .warm)
        let store = try await MainActor.run { try XCTUnwrap(DatabaseManager.shared.dbQueue) }
        try await store.write { db in
            try db.execute(sql: "UPDATE roles SET settings = ? WHERE id = ?", arguments: [#"{"icon_tint": "water", "autonomous_mode": "not a flag"}"#, odd.id])
        }
        let shown = try await RoleService.shared.getRole(roleId: odd.id)
        XCTAssertNil(shown.iconTintValue, "It shows sand")
        let next = try await RoleService.shared.createRole(covenId: fresh.id, name: "Next")
        XCTAssertEqual(next.iconTintValue, .water, "Water is worn by no one")

        // Settings that cannot be read are not written over by a new face.
        let queue = try await MainActor.run { try XCTUnwrap(DatabaseManager.shared.dbQueue) }
        try await queue.write { db in
            try db.execute(sql: "UPDATE roles SET settings = ? WHERE id = ?", arguments: ["not settings", writer.id])
        }
        do {
            try await RoleService.shared.setIcon(symbol: "star", tint: .plum, forRole: writer.id)
            XCTFail("Wrote over settings that could not be read")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This agent's settings could not be read")
        }
        let kept = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT settings FROM roles WHERE id = ?", arguments: [writer.id])
        }
        XCTAssertEqual(kept, "not settings")
        // Nor by the form that saves an agent's other settings: nothing of it is changed.
        do {
            _ = try await RoleService.shared.updateRole(roleId: writer.id, name: "Renamed", autonomousMode: true)
            XCTFail("Replaced settings that could not be read")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This agent's settings could not be read")
        }
        let untouched = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT name, settings FROM roles WHERE id = ?", arguments: [writer.id])
        }
        XCTAssertEqual(untouched?["name"], "Writer")
        XCTAssertEqual(untouched?["settings"], "not settings")
    }
}
