import Foundation

public struct TouchReportDecoder: Sendable {
    public init() {}

    public func decode(
        _ report: [UInt8],
        timestamp: TimeInterval,
        coordinateMaximum: UInt16 = TouchDeviceDescriptor.paperLike13KColor.coordinateMaximum
    ) throws -> TouchFrame {
        let descriptor = TouchDeviceDescriptor.paperLike13KColor
        guard report.count == descriptor.reportByteCount else {
            throw TouchReportError.invalidByteCount(report.count)
        }
        guard report[0] == descriptor.reportID else {
            throw TouchReportError.invalidReportID(report[0])
        }

        let contactCount = report[83]
        guard contactCount <= descriptor.contactSlotCount else {
            throw TouchReportError.contactCountOutOfRange(contactCount)
        }

        var contacts: [TouchContact] = []
        var activeIDs = Set<UInt8>()
        for slotIndex in 0..<descriptor.contactSlotCount {
            let offset = 1 + (slotIndex * descriptor.contactSlotByteCount)
            let isTouching = report[offset] & 0x01 != 0
            guard isTouching else { continue }

            let id = report[offset + 1]
            guard activeIDs.insert(id).inserted else {
                throw TouchReportError.duplicateContactID(id)
            }

            let x = UInt16(report[offset + 2]) | UInt16(report[offset + 3]) << 8
            let y = UInt16(report[offset + 4]) | UInt16(report[offset + 5]) << 8
            guard x <= coordinateMaximum, y <= coordinateMaximum else {
                throw TouchReportError.coordinateOutOfRange(x: x, y: y)
            }

            contacts.append(
                TouchContact(
                    id: id,
                    x: x,
                    y: y,
                    width: report[offset + 6],
                    isTouching: true
                )
            )
        }



        let scanTime = UInt16(report[81]) | UInt16(report[82]) << 8
        return TouchFrame(contacts: contacts, scanTime: scanTime, timestamp: timestamp)
    }
}
