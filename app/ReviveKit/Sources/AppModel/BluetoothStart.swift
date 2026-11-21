/// When the app creates the Bluetooth stack, and whether it opens on the tabs (product-spec.md
/// §2.1, §3.1). Creating the stack makes iOS ask for Bluetooth, which must only happen after
/// P01's "继续" has said what it is for, or when there is nothing left to ask. Pure rules, so the
/// one that matters most for 先不连卡 (no prompt before P01) is covered by tests; the app target
/// only calls them.
public enum BluetoothStart {
    /// At launch: with a paired card (pending connects must exist at once), when iOS relaunched
    /// the app for a card (state restoration), or once iOS has allowed Bluetooth (no prompt
    /// then). Otherwise the first use waits for P01.
    public static func atLaunch(hasPairedCard: Bool, restoringCard: Bool,
                                authorization: BluetoothAuthorization) -> Bool {
        hasPairedCard || restoringCard || authorization == .allowed
    }

    /// For the tabs: the real stack when it already exists, a card is paired, or iOS has already
    /// answered, allowed or denied (no prompt either way; denied shows Bluetooth as unavailable).
    /// Otherwise 先不连卡 runs the tabs on `NoCardLink`.
    public static func realStackForTabs(stackExists: Bool, hasPairedCard: Bool,
                                        authorization: BluetoothAuthorization) -> Bool {
        stackExists || hasPairedCard || authorization != .notDetermined
    }

    /// The tabs with a paired card or after 先不连卡; the first-use flow otherwise.
    public static func showsTabs(hasPairedCard: Bool, usesWithoutCard: Bool) -> Bool {
        hasPairedCard || usesWithoutCard
    }
}
