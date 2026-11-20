import AppModel
import Testing

// When the Bluetooth stack is created (product-spec.md §2.1, §3.1). The rule that matters most:
// before P01's "继续", nothing makes iOS ask for Bluetooth, also not 先不连卡.
struct BluetoothStartTests {
    private let all: [BluetoothAuthorization] = [.notDetermined, .allowed, .denied]

    @Test func nothingAsksBeforeP01() {
        // No card, no stack, iOS never asked: neither launch nor the tabs create the stack.
        #expect(!BluetoothStart.atLaunch(hasPairedCard: false, restoringCard: false, authorization: .notDetermined))
        #expect(!BluetoothStart.realStackForTabs(stackExists: false, hasPairedCard: false,
                                                 authorization: .notDetermined))
    }

    @Test func launchStartsForACardOrOnceAllowed() {
        for authorization in all {
            #expect(BluetoothStart.atLaunch(hasPairedCard: true, restoringCard: false, authorization: authorization))
            #expect(BluetoothStart.atLaunch(hasPairedCard: false, restoringCard: true, authorization: authorization))
        }
        #expect(BluetoothStart.atLaunch(hasPairedCard: false, restoringCard: false, authorization: .allowed))
        // Denied without a card: nothing to connect, so launch leaves it to the tabs or P01.
        #expect(!BluetoothStart.atLaunch(hasPairedCard: false, restoringCard: false, authorization: .denied))
    }

    @Test func tabsUseTheRealStackOnceThereIsNoQuestionLeft() {
        for authorization in all {
            #expect(BluetoothStart.realStackForTabs(stackExists: true, hasPairedCard: false,
                                                    authorization: authorization))
            #expect(BluetoothStart.realStackForTabs(stackExists: false, hasPairedCard: true,
                                                    authorization: authorization))
        }
        // Answered either way: no prompt, so the real stack (denied shows Bluetooth unavailable).
        #expect(BluetoothStart.realStackForTabs(stackExists: false, hasPairedCard: false, authorization: .allowed))
        #expect(BluetoothStart.realStackForTabs(stackExists: false, hasPairedCard: false, authorization: .denied))
    }

    @Test func tabsWithACardOrAfterUsingWithoutOne() {
        #expect(BluetoothStart.showsTabs(hasPairedCard: true, usesWithoutCard: false))
        #expect(BluetoothStart.showsTabs(hasPairedCard: false, usesWithoutCard: true))
        #expect(BluetoothStart.showsTabs(hasPairedCard: true, usesWithoutCard: true))
        #expect(!BluetoothStart.showsTabs(hasPairedCard: false, usesWithoutCard: false))
    }
}
