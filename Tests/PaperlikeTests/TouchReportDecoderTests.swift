import PaperlikeTouch

func touchReportDecoderTests() -> [TestCase] {
    [
        TestCase("TouchDeviceDescriptorTests.exposesPaperLike13KHIDMatchingValues") {
            let descriptor = TouchDeviceDescriptor.paperLike13KColor

            try expectEqual(descriptor.vendorID, 0x1A86)
            try expectEqual(descriptor.productID, 0xE5E3)
            try expectEqual(descriptor.usagePage, 13)
            try expectEqual(descriptor.usage, 4)
        },
        TestCase("TouchReportDecoderTests.decodesActiveContact") {
            let frame = try TouchReportDecoder().decode(
                makeTouchReport(contacts: [
                    .init(id: 7, x: 1024, y: 3072, isTouching: true)
                ]),
                timestamp: 12.5
            )

            try expect(frame.contacts == [
                TouchContact(id: 7, x: 1024, y: 3072, width: 20, isTouching: true)
            ], "active contact decodes")
        },
        TestCase("TouchReportDecoderTests.decodesLittleEndianScanTime") {
            let frame = try TouchReportDecoder().decode(
                makeTouchReport(contacts: [], scanTime: 0x1234),
                timestamp: 12.5
            )

            try expectEqual(frame.scanTime, 0x1234)
        },
        TestCase("TouchReportDecoderTests.rejectsWrongReportID") {
            var report = makeTouchReport(contacts: [])
            report[0] = 2

            try expectThrows(TouchReportError.invalidReportID(2)) {
                _ = try TouchReportDecoder().decode(report, timestamp: 0)
            }
        },
        TestCase("TouchReportDecoderTests.rejectsUnexpectedByteCount") {
            let report = Array(makeTouchReport(contacts: []).dropLast())

            try expectThrows(TouchReportError.invalidByteCount(83)) {
                _ = try TouchReportDecoder().decode(report, timestamp: 0)
            }
        },
        TestCase("TouchReportDecoderTests.rejectsContactCountAboveTen") {
            let report = makeTouchReport(contacts: [], contactCount: 11)

            try expectThrows(TouchReportError.contactCountOutOfRange(11)) {
                _ = try TouchReportDecoder().decode(report, timestamp: 0)
            }
        },
        TestCase("TouchReportDecoderTests.rejectsDuplicateActiveIDs") {
            let report = makeTouchReport(contacts: [
                .init(id: 4, x: 10, y: 20, isTouching: true),
                .init(id: 4, x: 30, y: 40, isTouching: true)
            ])

            try expectThrows(TouchReportError.duplicateContactID(4)) {
                _ = try TouchReportDecoder().decode(report, timestamp: 0)
            }
        },
        TestCase("TouchReportDecoderTests.rejectsCoordinatesAbove4096") {
            let report = makeTouchReport(contacts: [
                .init(id: 1, x: 4097, y: 0, isTouching: true)
            ])

            try expectThrows(
                TouchReportError.coordinateOutOfRange(x: 4097, y: 0)
            ) {
                _ = try TouchReportDecoder().decode(report, timestamp: 0)
            }
        },
        TestCase("TouchReportDecoderTests.acceptsValidatedHIDCoordinateMaximum") {
            let report = makeTouchReport(contacts: [.init(id: 1, x: 5_000, y: 6_000, isTouching: true)])
            let frame = try TouchReportDecoder().decode(report, timestamp: 0, coordinateMaximum: 8_192)

            try expectEqual(frame.contacts.first?.x, 5_000)
        },

    ]
}

private struct TouchReportFixtureContact {
    let id: UInt8
    let x: UInt16
    let y: UInt16
    let width: UInt8
    let isTouching: Bool

    init(id: UInt8, x: UInt16, y: UInt16, width: UInt8 = 20, isTouching: Bool) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.isTouching = isTouching
    }
}

private func makeTouchReport(
    contacts: [TouchReportFixtureContact],
    contactCount: UInt8? = nil,
    scanTime: UInt16 = 0
) -> [UInt8] {
    precondition(contacts.count <= 10)

    var report = Array(repeating: UInt8(0), count: 84)
    report[0] = 1

    for (index, contact) in contacts.enumerated() {
        let offset = 1 + (index * 8)
        report[offset] = contact.isTouching ? 0x01 : 0x00
        report[offset + 1] = contact.id
        report[offset + 2] = UInt8(truncatingIfNeeded: contact.x)
        report[offset + 3] = UInt8(truncatingIfNeeded: contact.x >> 8)
        report[offset + 4] = UInt8(truncatingIfNeeded: contact.y)
        report[offset + 5] = UInt8(truncatingIfNeeded: contact.y >> 8)
        report[offset + 6] = contact.width
    }

    report[81] = UInt8(truncatingIfNeeded: scanTime)
    report[82] = UInt8(truncatingIfNeeded: scanTime >> 8)
    report[83] = contactCount ?? UInt8(contacts.filter(\.isTouching).count)
    return report
}
