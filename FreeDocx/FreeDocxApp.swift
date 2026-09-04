//
//  FreeDocxApp.swift
//  FreeDocx
//
//  Created by Siavash Bonakdar on 8/30/26.
//

import AppKit
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct FreeDocxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { FreeDocxDocument() }) { file in
            ContentView(document: file.document)
        }
    }
}
