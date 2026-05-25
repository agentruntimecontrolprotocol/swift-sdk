import Foundation
import Testing

@testable import ARCP

@Suite("Mailbox queue (issue #49)")
struct MailboxTests {
    @Test("drain returns items in FIFO order")
    func fifoOrder() async {
        let mailbox = Mailbox<Int>()
        for i in 0..<10 { await mailbox.put(i) }
        await mailbox.finish()
        var out: [Int] = []
        while let value = await mailbox.next() { out.append(value) }
        #expect(out == Array(0..<10))
    }

    @Test("large bursty drain compacts without quadratic shifting")
    func largeBurst() async {
        let mailbox = Mailbox<Int>()
        let total = 5_000
        for i in 0..<total { await mailbox.put(i) }
        await mailbox.finish()
        var count = 0
        var last = -1
        while let value = await mailbox.next() {
            #expect(value == last + 1)
            last = value
            count += 1
        }
        #expect(count == total)
    }
}
