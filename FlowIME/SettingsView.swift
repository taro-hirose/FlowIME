//
//  SettingsView.swift
//  FlowIME
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("AutoSwitchEnabled") private var autoSwitchEnabled: Bool = true
    @AppStorage("IdleGapForEN") private var idleGap: Double = 0.2

    private func idleGapLabel(_ v: Double) -> String {
        if v <= 0.0001 { return "Off" }
        return String(format: "%.2fs", v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FlowIME Settings").font(.headline)

            Toggle("Auto Switch", isOn: $autoSwitchEnabled)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("EN Idle Gap (JP→EN allowance)")
                    Spacer()
                    Text(idleGapLabel(idleGap)).foregroundColor(.secondary)
                }
                HStack {
                    Text("Off")
                    Slider(value: $idleGap, in: 0.0...0.5, step: 0.05)
                    Text("0.50s")
                }
                Text("When set > 0, EN is allowed after a short pause during JP typing. Set Off to require navigation (arrow/click/newline/app switch).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Divider()
            Text("More options coming soon (navigation window, logging level, hotkeys)…")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack { Spacer() }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View { SettingsView() }
}

