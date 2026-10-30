import PaperlikeProtocol

func responseStreamDecoderTests() -> [TestCase] {
    [
        TestCase("ResponseStreamDecoderTests.decodesResponseFields") {
        let response = try PaperlikeResponse.decode(
            Array("5FF5F00A010100000000A0FA".utf8)
        )

        try expectEqual(response.command, 0xF0)
        try expectEqual(response.field1, 0x0A)
        try expectEqual(response.field2, 0x01)
        try expectEqual(response.field3, 0x01)
        },
        TestCase("ResponseStreamDecoderTests.rejectsInvalidHeader") {
            try expectThrows(PaperlikeProtocolError.invalidHeader) {
                _ = try PaperlikeResponse.decode(
                    Array("0000F00A010100000000A0FA".utf8)
                )
            }
        },
        TestCase("ResponseStreamDecoderTests.rejectsInvalidTrailer") {
            try expectThrows(PaperlikeProtocolError.invalidTrailer) {
                _ = try PaperlikeResponse.decode(
                    Array("5FF5F00A0101000000000000".utf8)
                )
            }
        },
        TestCase("ResponseStreamDecoderTests.decodesSplitFrames") {
        var decoder = ResponseStreamDecoder()

        try expect(
            try decoder.append(Array("5FF5F00A0101".utf8)).isEmpty,
            "first half must not emit a response"
        )
        try expectEqual(
            try decoder.append(Array("00000000A0FA".utf8)).count,
            1
        )
        },
        TestCase("ResponseStreamDecoderTests.decodesJoinedFrames") {
        var decoder = ResponseStreamDecoder()
        let bytes = Array(
            (
                "noise"
                + "5FF5F00A010100000000A0FA"
                + "5FF5F00A020200000000A0FA"
            ).utf8
        )

        let responses = try decoder.append(bytes)

        try expectEqual(responses.count, 2)
        try expectEqual(responses[0].field2, 0x01)
        try expectEqual(responses[1].field2, 0x02)
        },
        TestCase("ResponseStreamDecoderTests.retainsPartialHeader") {
        var decoder = ResponseStreamDecoder()

        try expect(
            try decoder.append(Array("junk5F".utf8)).isEmpty,
            "noise plus partial header must not emit a response"
        )
        let responses = try decoder.append(
            Array("F5F00A010100000000A0FA".utf8)
        )

        try expectEqual(responses.count, 1)
        try expectEqual(responses[0].field3, 0x01)
        },
        TestCase("ResponseStreamDecoderTests.resynchronizesAfterMalformedFrame") {
            var decoder = ResponseStreamDecoder()
            let responses = try decoder.append(
                Array(
                    (
                        "5FF5F5205FF5F52000000000"
                        + "5FF5F00A103011100001A0FA"
                    ).utf8
                )
            )

            try expectEqual(responses.count, 1)
            try expectEqual(responses[0].field2, 0x10)
            try expectEqual(responses[0].field3, 0x30)
        }
    ]
}
