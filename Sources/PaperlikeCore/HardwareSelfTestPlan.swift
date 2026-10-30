public enum HardwareSelfTestPlan {
    public static func speedRoundTrip(
        from readableSpeed: Int?
    ) -> (alternate: Int, restore: Int)? {
        guard let readableSpeed else {
            return nil
        }
        return (
            alternate: readableSpeed == 5 ? 4 : readableSpeed + 1,
            restore: readableSpeed
        )
    }
}
