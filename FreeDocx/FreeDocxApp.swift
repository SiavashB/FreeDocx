//
//  FreeDocxApp.swift
//  FreeDocx
//
//  Created by Siavash Bonakdar on 8/30/26.
//

import SwiftUI

@main
struct FreeDocxApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: FreeDocxDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
