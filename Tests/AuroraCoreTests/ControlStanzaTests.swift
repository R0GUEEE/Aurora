import XCTest
@testable import AuroraCore

/// ``ControlParser``/``ControlStanza`` must be lossless: Aurora rewrites
/// `/var/lib/dpkg/status` after every transaction, and a field it drops or
/// reorders is a field dpkg or a maintainer script stops trusting.
final class ControlStanzaTests: XCTestCase {

    // MARK: - Parsing the index

    func testParsesEveryStanzaOfTheIndex() throws {
        let stanzas = ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
        XCTAssertEqual(stanzas.count, 16)
        XCTAssertEqual(stanzas.map { $0["Package"] ?? "" },
                       ["bash", "coreutils", "libfoo1", "foo-app", "foo-app", "newapp", "oldapp",
                        "plugin", "plugin", "mailserver", "mailclient", "brokenapp", "cyc-a",
                        "cyc-b", "arch-all-tool", "legacy-tweak"])
        XCTAssertTrue(stanzas.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(stanzas.filter { $0["Package"] == "foo-app" }.map { $0["Version"] ?? "" },
                       ["2.0.0-1", "1.9.0-1"])
        XCTAssertEqual(stanzas.filter { $0["Package"] == "plugin" }.map { $0["Version"] ?? "" },
                       ["3.1-1", "3.0-1"])
    }

    func testFieldOrderAndSpellingSurviveParsing() throws {
        let stanzas = ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
        let bash = try XCTUnwrap(stanzas.first)
        XCTAssertEqual(bash.fields.map(\.name),
                       ["Package", "Version", "Architecture", "Essential", "Section", "Installed-Size",
                        "Maintainer", "Description", "Filename", "Size", "SHA256", "MD5sum"])
        XCTAssertEqual(bash.fields.first?.value, "bash")

        let halfbroken = try XCTUnwrap(
            ControlParser.parse("Package: halfbroken\nConffiles: \n  /etc/halfbroken.conf deadbeef\n").first)
        XCTAssertEqual(halfbroken.fields.map(\.name), ["Package", "Conffiles"])
        XCTAssertEqual(halfbroken["Conffiles"], "\n /etc/halfbroken.conf deadbeef")
    }

    // MARK: - Accessors

    func testAccessorsAreCaseInsensitiveAndTyped() throws {
        let stanzas = ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
        let bash = try XCTUnwrap(stanzas.first)

        XCTAssertEqual(bash["Package"], "bash")
        XCTAssertEqual(bash["PACKAGE"], "bash")
        XCTAssertEqual(bash.string("package"), "bash")
        XCTAssertTrue(bash.has("essential"))
        XCTAssertFalse(bash.has("Depends"))
        XCTAssertNil(bash.string("Depends"), "an absent field is nil, not an empty string")
        XCTAssertTrue(bash.bool("Essential"))
        XCTAssertFalse(bash.bool("Section"), "only 'yes'/'true' are true")
        XCTAssertEqual(bash.int("Installed-Size"), 1580)
        XCTAssertEqual(bash.int("Size"), 478096)
        XCTAssertNil(bash.int("Maintainer"))
    }

    func testStringTreatsEmptyAsAbsent() {
        var stanza = ControlStanza(fields: [ControlField(name: "Package", value: "x"),
                                            ControlField(name: "Depends", value: "")])
        XCTAssertEqual(stanza["Depends"], "", "the subscript returns the field itself")
        XCTAssertNil(stanza.string("Depends"), "string() maps empty to nil")
        stanza["Empty"] = "   "
        XCTAssertEqual(stanza.string("Empty"), "   ")

        XCTAssertEqual(stanza.commaSeparated("Depends"), [])
        XCTAssertEqual(ControlStanza().commaSeparated("Tag"), [])
        let tagged = ControlStanza(fields: [
            ControlField(name: "Tag", value: "role::program, scope::utility , uitoolkit::ncurses"),
        ])
        XCTAssertEqual(tagged.commaSeparated("Tag"),
                       ["role::program", "scope::utility", "uitoolkit::ncurses"])
    }

    func testSubscriptMutatesInPlaceAndKeepsOrder() {
        var stanza = ControlStanza(fields: [ControlField(name: "Package", value: "x")])
        XCTAssertEqual(stanza["Package"], "x")

        stanza["Version"] = "1.0-1"
        XCTAssertEqual(stanza.fields.map(\.name), ["Package", "Version"])

        stanza["package"] = "y"
        XCTAssertEqual(stanza.fields.count, 2, "an update must not append a second field")
        XCTAssertEqual(stanza.fields.first?.name, "Package", "spelling is kept, only the value changes")
        XCTAssertEqual(stanza["Package"], "y")

        stanza["Version"] = nil
        XCTAssertEqual(stanza.fields.map(\.name), ["Package"])
        XCTAssertNil(stanza["Version"])
        XCTAssertFalse(stanza.has("version"))

        stanza["Version"] = "2.0"
        XCTAssertEqual(stanza.fields.map(\.name), ["Package", "Version"])
        XCTAssertEqual(stanza["Version"], "2.0")
        XCTAssertTrue(ControlStanza().isEmpty)
    }

    // MARK: - Descriptions

    func testMultiLineDescriptionFoldingAndParts() throws {
        let stanzas = ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
        let bash = try XCTUnwrap(stanzas.first { $0["Package"] == "bash" })
        XCTAssertEqual(bash["Description"],
                       "The GNU Bourne Again SHell\n A shell that everything else assumes is present.")
        XCTAssertEqual(bash.descriptionParts.synopsis, "The GNU Bourne Again SHell")
        XCTAssertEqual(bash.descriptionParts.body, " A shell that everything else assumes is present.")

        let coreutils = try XCTUnwrap(stanzas.first { $0["Package"] == "coreutils" })
        XCTAssertEqual(coreutils.descriptionParts.synopsis, "Core utilities")
        XCTAssertNil(coreutils.descriptionParts.body, "a single-line description has no body")

        let folded = try XCTUnwrap(
            ControlParser.parse("Description: Synopsis\n .\n More text\n More text again\n").first)
        XCTAssertEqual(folded["Description"], "Synopsis\n.\nMore text\nMore text again")
        XCTAssertEqual(folded.descriptionParts.synopsis, "Synopsis")
        XCTAssertEqual(folded.descriptionParts.body, "\nMore text\nMore text again")

        let noDescription = try XCTUnwrap(ControlParser.parse("Package: x\n").first)
        XCTAssertEqual(noDescription.descriptionParts.synopsis, "")
        XCTAssertNil(noDescription.descriptionParts.body)
    }

    // MARK: - Lossless round trip

    /// The guarantee the dpkg status writer depends on.
    func testStatusFileRoundTripIsLossless() throws {
        let text = try Fixture.text(Fixture.status)
        let stanzas = ControlParser.parse(text)
        XCTAssertEqual(stanzas.count, 7)

        // Serialising reproduces the file byte for byte, plus the blank line that
        // terminates the last stanza.
        let rendered = stanzas.map(\.serialized).joined()
        XCTAssertEqual(rendered, text + "\n")

        let reparsed = ControlParser.parse(rendered)
        XCTAssertEqual(reparsed, stanzas)
        XCTAssertEqual(reparsed.map(\.serialized).joined(), rendered, "serialisation must be idempotent")
    }

    func testPackagesFileRoundTripIsLossless() throws {
        let text = try Fixture.text(Fixture.packagesIndex)
        let stanzas = ControlParser.parse(text)
        let rendered = stanzas.map(\.serialized).joined()
        XCTAssertEqual(rendered, text + "\n")
        XCTAssertEqual(ControlParser.parse(rendered), stanzas)
    }

    func testSerializedRendersContinuationLinesAndBlankLines() {
        let stanza = ControlStanza(fields: [
            ControlField(name: "Package", value: "x"),
            ControlField(name: "Description", value: "Synopsis\n.\nSecond paragraph"),
        ])
        XCTAssertEqual(stanza.serialized, "Package: x\nDescription: Synopsis\n .\n Second paragraph\n\n")

        // An empty continuation line is a lone space, except inside `Description`
        // where the ` .` convention is what every other control-file tool reads.
        let blank = ControlStanza(fields: [ControlField(name: "Tag", value: "a\n\nb")])
        XCTAssertEqual(blank.serialized, "Tag: a\n \n b\n\n")
        XCTAssertEqual(ControlParser.parse(blank.serialized).first, blank)

        let description = ControlStanza(fields: [ControlField(name: "Description", value: "Synopsis\n.\nBody")])
        XCTAssertEqual(description.serialized, "Description: Synopsis\n .\n Body\n\n")
        XCTAssertEqual(ControlParser.parse(description.serialized).first, description)

        let mixed = ControlStanza(fields: [
            ControlField(name: "Conffiles", value: "\n /etc/x.conf"),
            ControlField(name: "Description", value: "S\n\nBody"),
        ])
        XCTAssertEqual(mixed.serialized, "Conffiles: \n  /etc/x.conf\nDescription: S\n .\n Body\n\n")
        // A truly empty line inside a Description is not preserved as an empty
        // line — it comes back as ` .` — but serialising is idempotent from there.
        let roundTripped = ControlParser.parse(mixed.serialized)
        XCTAssertEqual(roundTripped.count, 1)
        XCTAssertEqual(roundTripped.first?.serialized, mixed.serialized)

        XCTAssertEqual(ControlStanza().serialized, "\n")
    }

    // MARK: - Damage tolerance

    func testCRLFAndMalformedLinesAreTolerated() {
        let text = "Package: one\r\n"
            + "Version: 1.0\r\n"
            + "Broken line without a colon\r\n"
            + "\r\n"
            + "Package: two\r\n"
            + "Version: 2.0\r\n"
            + "Description: has a colon: inside\r\n"
        let stanzas = ControlParser.parse(text)
        XCTAssertEqual(stanzas.count, 2)
        XCTAssertEqual(stanzas[0].fields.map(\.name), ["Package", "Version"],
                       "the malformed line is dropped, not folded into the previous field")
        XCTAssertEqual(stanzas[0]["Version"], "1.0")
        XCTAssertEqual(stanzas[1].fields.map(\.name), ["Package", "Version", "Description"])
        XCTAssertEqual(stanzas[1]["Description"], "has a colon: inside")
    }

    func testBlankRunsAndEmptyInputProduceNothing() {
        XCTAssertTrue(ControlParser.parse("").isEmpty)
        XCTAssertTrue(ControlParser.parse("\n\n\n").isEmpty)
        XCTAssertTrue(ControlParser.parse("   \n\t\n").isEmpty)
        XCTAssertEqual(ControlParser.parse("\n\nPackage: x\n\n\n").count, 1)
        XCTAssertEqual(ControlParser.parse(Data("Package: x\nVersion: 1.0\n".utf8)).count, 1)
    }

    func testContinuationWithoutPrecedingFieldIsIgnored() {
        let stanzas = ControlParser.parse(" orphan continuation\nPackage: x\n")
        XCTAssertEqual(stanzas.count, 1)
        XCTAssertEqual(stanzas[0].fields.map(\.name), ["Package"])
        XCTAssertEqual(stanzas[0]["Package"], "x", "the orphan line is dropped")
    }

    func testIndentedLinesAlwaysFoldIntoThePreviousField() {
        // Even a line that *looks* like a field becomes part of the previous
        // value: that is how dpkg reads an rfc822 stanza, and how the `Conffiles`
        // field in the status fixture is laid out.
        let stanzas = ControlParser.parse("Package: x\n Version: 1.0\n")
        XCTAssertEqual(stanzas.count, 1)
        XCTAssertEqual(stanzas[0].fields.map(\.name), ["Package"])
        XCTAssertEqual(stanzas[0]["Package"], "x\nVersion: 1.0")
        XCTAssertNil(stanzas[0]["Version"])
    }
}
