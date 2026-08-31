//
//  ContentView.swift
//  FreeDocx
//
//  Created by Siavash Bonakdar on 8/30/26.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: FreeDocxDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(FreeDocxDocument()))
}
