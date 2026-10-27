// ControllerMenuView.swift — Pause menu for game controllers
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

/// [iPSX2 #18] The pause menu a controller opens (see ControllerNavigator): D-pad or left stick to
/// move, A to choose, B to go back. Rows are plain views rather than Buttons on purpose: iPadOS moves
/// its own focus with the D-pad, and focusable buttons would react to the A button as well.
struct ControllerMenuView: View {
    @State private var navigator = ControllerNavigator.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { navigator.close() }

            VStack(alignment: .leading, spacing: 12) {
                Text(navigator.title)
                    .font(.title2.weight(.bold))

                let rows = navigator.items
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == navigator.selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { navigator.activate(index: index) }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(rows.count) * 46, 460))
                    .onChange(of: navigator.selection) { _, newValue in
                        guard rows.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(rows[newValue].id, anchor: .center)
                        }
                    }
                }

                if let message = navigator.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Label("Select", systemImage: "a.circle")
                    Label("Back", systemImage: "b.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
    }

    private func row(_ item: ControllerMenuItem, selected: Bool) -> some View {
        HStack {
            Text(item.title)
                .font(.body.weight(selected ? .semibold : .regular))
            Spacer(minLength: 12)
            if let detail = item.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(item.isEnabled ? 1 : 0.4)
    }
}
