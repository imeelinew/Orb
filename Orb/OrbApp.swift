//
//  OrbApp.swift
//  Orb
//
//  Created by Eli New on 2026-06-01.
//

import AppKit
import SwiftUI

@main
struct OrbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
