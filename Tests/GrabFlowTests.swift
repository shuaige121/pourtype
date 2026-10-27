import XCTest
@testable import Pourtype

/// Grab Text after the box is drawn: recognition off the main thread, the warm-up, the same text as before.
final class GrabFlowTests: XCTestCase {
    private func image() throws -> CGImage { try XCTUnwrap(Grabber.warmUpImage()) }

    /// read() returns at once; while recognition takes its time, the main thread keeps running; the result
    /// comes back on main.
    func testRecognitionRunsOffTheMainThread() throws {
        let img = try image()
        let done = expectation(description: "read")
        var recognizedOnMain: Bool?, deliveredOnMain: Bool?, text: String?
        var mainRan: Double?, finished: Double?
        let t0 = now()
        Grabber.read(img, asciiPunct: true, thumbnail: false, recognize: { _ in
            recognizedOnMain = Thread.isMainThread
            usleep(400_000)                                          // a slow, cold Vision
            return "  Price：10  "
        }) { r in
            deliveredOnMain = Thread.isMainThread
            finished = now()
            text = try? r.get().text
            done.fulfill()
        }
        let returned = now() - t0
        DispatchQueue.main.async { mainRan = now() }
        wait(for: [done], timeout: 5)
        XCTAssertLessThan(returned, 0.05)
        XCTAssertEqual(recognizedOnMain, false)
        XCTAssertEqual(deliveredOnMain, true)
        XCTAssertLessThan(try XCTUnwrap(mainRan) - t0, 0.2)        // not stuck behind the 0.4 s recognition
        XCTAssertGreaterThan(try XCTUnwrap(finished) - t0, 0.39)
        XCTAssertEqual(text, "Price:10")
    }

    /// The text the clipboard gets is built as before: trimmed, then half-width punctuation when that is on.
    func testTheTextIsTheSameAsBefore() throws {
        let raw = "  Price：10，中文：好 \n"
        let before = { (ascii: Bool) -> String in
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if ascii { t = Grabber.asciiPunct(t) }
            return t
        }
        for ascii in [true, false] { XCTAssertEqual(Grabber.clean(raw, asciiPunct: ascii), before(ascii)) }
        let done = expectation(description: "read")
        var reading: Grabber.Reading?
        Grabber.read(try image(), asciiPunct: true, thumbnail: true, recognize: { _ in raw }) { r in
            reading = try? r.get(); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reading?.text, before(true))
        XCTAssertNotNil(reading?.png)                                 // the history still gets the screenshot
    }

    func testRecognitionErrorsReachTheCaller() throws {
        struct Boom: Error {}
        let done = expectation(description: "read")
        var failed = false
        Grabber.read(try image(), asciiPunct: true, thumbnail: true, recognize: { _ in throw Boom() }) { r in
            if case .failure(let e) = r { failed = e is Boom }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(failed)
    }

    /// The warm-up returns at once and recognises a picture of text off the main thread.
    func testTheWarmUpDoesNotBlockAndRunsOffTheMainThread() {
        let ran = expectation(description: "warm-up")
        var onMain: Bool?, size: (Int, Int)?
        let t0 = now()
        Grabber.warmUp(after: 0.05) { img in
            onMain = Thread.isMainThread
            size = (img.width, img.height)
            ran.fulfill()
            return ""
        }
        XCTAssertLessThan(now() - t0, 0.01)
        wait(for: [ran], timeout: 5)
        XCTAssertEqual(onMain, false)
        XCTAssertGreaterThan(size?.0 ?? 0, 100)
    }

    /// This process's memory footprint in MB (what Activity Monitor shows as Memory).
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// The warm-up picture is real text for Vision (so warming loads the text models), read on the Vision queue.
    /// Prints how long the first and second recognitions took in this process, and the memory they added.
    func testVisionReadsTheWarmUpPicture() throws {
        let img = try image()
        let mb0 = footprintMB()
        var times: [Double] = [], texts: [String] = []
        for _ in 0..<2 {
            let done = expectation(description: "vision")
            let t0 = now()
            Grabber.read(img, asciiPunct: true, thumbnail: false) { r in
                times.append(now() - t0)
                texts.append((try? r.get().text) ?? "")
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
        }
        print(String(format: "VISION_TIMING first=%.0f ms second=%.0f ms footprint %.0f MB -> %.0f MB",
                     times[0] * 1000, times[1] * 1000, mb0, footprintMB()))
        XCTAssertTrue(texts.allSatisfy { $0.contains("2468") }, "\(texts)")
    }
}
