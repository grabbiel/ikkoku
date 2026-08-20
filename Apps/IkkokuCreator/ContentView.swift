//
//  ContentView.swift
//  IkkokuCreator
//
//  Created by rumpology on 8/18/26.
//

import SwiftUI
import GPU

struct ContentView: View {
    private let gpu = GPUContext()

    var body: some View {
        if let gpu {
            MetalHostView(gpu: gpu)
                .frame(minWidth: 960, minHeight: 640)
        } else {
            Text("Metal is unavailable on this system.")
                .frame(minWidth: 400, minHeight: 200)
        }
    }
}
