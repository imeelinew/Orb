//
//  OrbTests.swift
//  OrbTests
//
//  Created by Eli New on 2026-06-01.
//

import AppKit
import Testing
@testable import Orb

struct OrbTests {

    @Test func statusItemClicksRespondOnMouseDown() {
        #expect(StatusItemClickHandling.actionEventMask.contains(.leftMouseDown))
        #expect(StatusItemClickHandling.actionEventMask.contains(.rightMouseDown))
        #expect(!StatusItemClickHandling.actionEventMask.contains(.leftMouseUp))
        #expect(!StatusItemClickHandling.actionEventMask.contains(.rightMouseUp))
    }

    @Test func statusItemClickActionsAreImmediateAndDistinct() {
        #expect(StatusItemClickHandling.action(for: .leftMouseDown) == .primary)
        #expect(StatusItemClickHandling.action(for: .rightMouseDown) == .secondary)
        #expect(StatusItemClickHandling.action(for: .leftMouseUp) == .ignore)
        #expect(StatusItemClickHandling.action(for: .rightMouseUp) == .ignore)
    }

    @Test func chatResponseAcceptsReasoningContentFallback() throws {
        let data = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "reasoning_content": " OK "
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let content = try RemoteCorrectionClient.decodeChatContent(from: data)

        #expect(content == "OK")
    }

    @Test func chatResponseWithoutContentDecodesEmptyString() throws {
        let data = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let content = try RemoteCorrectionClient.decodeChatContent(from: data)

        #expect(content.isEmpty)
    }

}
