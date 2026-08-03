import XCTest

@testable import ScoreboardCore

final class MappingTests: XCTestCase {
    // Tests never touch a real terminal adapter.
    let noOrigin: () -> [String: String]? = { nil }

    func hook(_ name: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "hook_event_name": name, "session_id": "s1", "cwd": "/tmp/proj",
        ]
        payload.merge(fields) { _, new in new }
        return payload
    }

    func assertState(
        _ payload: [String: Any], _ state: String, _ reason: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let event = Mapping.mapHook(payload, captureOrigin: noOrigin)
        XCTAssertNotNil(event, file: file, line: line)
        XCTAssertEqual(event?["state"] as? String, state, file: file, line: line)
        if let reason {
            XCTAssertEqual(event?["reason"] as? String, reason, file: file, line: line)
        }
    }

    func testSessionStartIsIdle() {
        assertState(hook("SessionStart"), "idle", "session_start")
    }

    func testPromptSubmit() {
        assertState(hook("UserPromptSubmit"), "running", "prompt")
    }

    func testStop() {
        assertState(hook("Stop"), "idle", "stop")
    }

    func testNotificationIdleTyped() {
        assertState(hook("Notification", ["notification_type": "idle_prompt"]), "idle", "idle")
    }

    func testNotificationIdleTypelessMessage() {
        assertState(
            hook("Notification", ["message": "Claude is waiting for your input"]), "idle", "idle")
    }

    func testNotificationPermissionMessageIsWaiting() {
        assertState(
            hook("Notification", ["message": "Claude needs your permission to use Bash"]),
            "waiting", "notification")
    }

    func testNotificationTypedNonIdleIsWaiting() {
        assertState(
            hook(
                "Notification",
                ["notification_type": "permission", "message": "finished, needs permission"]),
            "waiting", "notification")
    }

    func testPermissionRequest() {
        assertState(hook("PermissionRequest", ["tool_name": "Bash"]), "waiting", "permission_request")
    }

    func testPermissionRequestAskQuestion() {
        assertState(
            hook("PermissionRequest", ["tool_name": "AskUserQuestion"]), "waiting", "question")
    }

    func testPreToolUseAskQuestion() {
        assertState(hook("PreToolUse", ["tool_name": "AskUserQuestion"]), "waiting", "question")
    }

    func testPreToolUseOtherToolsIgnored() {
        XCTAssertNil(
            Mapping.mapHook(hook("PreToolUse", ["tool_name": "Bash"]), captureOrigin: noOrigin))
    }

    // The resume path: nothing else fires when a question is answered or a
    // permission granted.
    func testPostToolUseAskQuestionResumes() {
        assertState(
            hook("PostToolUse", ["tool_name": "AskUserQuestion"]), "running", "question_answered")
    }

    func testPostToolUseAnyToolResumes() {
        assertState(hook("PostToolUse", ["tool_name": "Bash"]), "running", "tool_done")
    }

    func testStopFailure() {
        assertState(hook("StopFailure"), "error")
    }

    func testSessionEnd() {
        assertState(hook("SessionEnd"), "ended", "session_end")
    }

    func testUnknownEventIgnored() {
        XCTAssertNil(Mapping.mapHook(hook("SubagentStop"), captureOrigin: noOrigin))
    }

    func testMissingSessionIDIgnored() {
        XCTAssertNil(
            Mapping.mapHook(["hook_event_name": "Stop"], captureOrigin: noOrigin))
    }

    func testGarbagePayloadsNeverCrash() {
        XCTAssertNil(Mapping.mapHook([:], captureOrigin: noOrigin))
        XCTAssertNil(Mapping.mapHook(["session_id": 7], captureOrigin: noOrigin))
        XCTAssertNil(Mapping.mapHook(["session_id": ""], captureOrigin: noOrigin))
    }

    func testEventShape() {
        let event = Mapping.mapHook(hook("Stop"), captureOrigin: noOrigin, parentPID: 4242)
        XCTAssertEqual(event?["v"] as? Int, 1)
        XCTAssertEqual(event?["session_id"] as? String, "s1")
        XCTAssertEqual(event?["title"] as? String, "proj")
        XCTAssertEqual(event?["cwd"] as? String, "/tmp/proj")
        XCTAssertEqual(event?["pid"] as? Int, 4242)
        XCTAssertNotNil(event?["ts"] as? Double)
    }

    func testMissingCwdGetsFallbackTitle() {
        let event = Mapping.mapHook(
            ["hook_event_name": "Stop", "session_id": "s1"], captureOrigin: noOrigin)
        XCTAssertEqual(event?["title"] as? String, "claude")
    }

    func testOriginCapturedOnSessionStart() {
        let origin = ["kind": "fake", "terminal_id": "T-1"]
        let event = Mapping.mapHook(hook("SessionStart"), captureOrigin: { origin })
        XCTAssertEqual(event?["origin"] as? [String: String], origin)
    }

    func testOriginNotCapturedOnOtherEvents() {
        let origin = ["kind": "fake", "terminal_id": "T-1"]
        for name in ["UserPromptSubmit", "Stop", "SessionEnd"] {
            let event = Mapping.mapHook(hook(name), captureOrigin: { origin })
            XCTAssertNil(event?["origin"], name)
        }
    }

    func testOriginAbsentWhenCaptureFails() {
        let event = Mapping.mapHook(hook("SessionStart"), captureOrigin: noOrigin)
        XCTAssertNil(event?["origin"])
    }
}
