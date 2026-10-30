import PaperlikeProtocol

func paperlikeFrameTests() -> [TestCase] {
    [
        TestCase("PaperlikeFrameTests.encodesModeRequestAsUppercaseASCII") {
        let bytes = try PaperlikeRequest(
            command: .mode,
            parameter: 3
        ).encoded()

        try expectEqual(
            String(decoding: bytes, as: UTF8.self),
            "5FF50203000000000000A0FA"
        )
        },
        TestCase("PaperlikeFrameTests.rejectsOutOfRangeParameter") {
            try expectThrows(
                PaperlikeProtocolError.parameterOutOfRange(256)
            ) {
                _ = try PaperlikeRequest(
                command: .mode,
                parameter: 256
            ).encoded()
            }
        }
    ]
}
