import SwiftUI

struct FormattingToolbar: View {
    @ObservedObject var controller: RichTextEditorController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let formatting = controller.formatting
        HStack(spacing: 5) {
            Button(action: controller.showFonts) {
                HStack(spacing: 10) {
                    Text("Aa").font(.system(size: 14))
                    chevron
                }
                .padding(.trailing, 3)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Fonts")
            .help("Choose a Font")

            FontSizeControl(size: formatting.fontSize, apply: controller.setFontSize)

            separator

            Button(action: controller.showColors) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: formatting.textColor))
                        .overlay { Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 1) }
                        .frame(width: 14, height: 14)
                    chevron
                }
                .padding(.leading, 3)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Text Color")
            .help("Show Text Colors")

            separator

            tool("Bold", selected: formatting.isBold, action: controller.toggleBold) {
                Text("B").fontWeight(.semibold)
            }
            .keyboardShortcut("b")
            .help("Bold (⌘B)")
            tool("Italic", selected: formatting.isItalic, action: controller.toggleItalic) {
                Text("I").font(.custom("Georgia-Italic", size: 16))
            }
            .keyboardShortcut("i")
            .help("Italic (⌘I)")
            tool("Underline", selected: formatting.isUnderlined, action: controller.toggleUnderline) {
                Text("U").underline()
            }
            .keyboardShortcut("u")
            .help("Underline (⌘U)")

            separator

            tool("Align Left", selected: formatting.alignment == .left, action: controller.alignLeft) {
                Image(systemName: "text.alignleft")
            }
            tool("Align Center", selected: formatting.alignment == .center, action: controller.alignCenter) {
                Image(systemName: "text.aligncenter")
            }
            tool("Align Right", selected: formatting.alignment == .right, action: controller.alignRight) {
                Image(systemName: "text.alignright")
            }

            separator

            tool("Add or Remove Bullets", selected: formatting.isList, action: controller.toggleBulletedList) {
                Image(systemName: "list.bullet")
            }
        }
        .font(.system(size: 16))
        .imageScale(.small)
        .buttonStyle(.plain)
        .foregroundStyle(colorScheme == .dark ? Color.primary : Color(red: 0.082, green: 0.106, blue: 0.169))
        .padding(.horizontal, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 44)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.973, green: 0.976, blue: 0.988))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color(nsColor: .separatorColor) : Color(red: 0.851, green: 0.871, blue: 0.906))
                .frame(height: 1)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .medium))
            .frame(width: 9)
    }

    private var separator: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color(nsColor: .separatorColor) : Color(red: 0.878, green: 0.894, blue: 0.925))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }

    private func tool(
        _ name: String,
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 26, height: 28)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color(red: 0.906, green: 0.922, blue: 0.949))
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(name)
    }
}

private struct FontSizeControl: View {
    let size: CGFloat?
    let apply: (CGFloat) -> Void

    @State private var draft: String?
    @FocusState private var isEditing: Bool
    @Environment(\.locale) private var locale

    private let presets = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 28, 36, 48, 72]
    private var numberFormat: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).locale(locale)
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField("—", text: Binding(
                get: { draft ?? size.map { numberFormat.format(Double($0)) } ?? "" },
                set: { draft = $0 }
            ))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13).monospacedDigit())
            .frame(width: 43)
            .focused($isEditing)
            .accessibilityLabel("Font size in points")
            .help("Type a size in points and press Return")
            .onSubmit(submit)
            .onChange(of: isEditing) { _, focused in
                if !focused { draft = nil }
            }

            Menu {
                ForEach(presets, id: \.self) { points in
                    Button {
                        draft = nil
                        apply(CGFloat(points))
                    } label: {
                        if size == CGFloat(points) {
                            Label("\(points) pt", systemImage: "checkmark")
                        } else {
                            Text("\(points) pt")
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .frame(width: 17, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Choose a font size")
            .help("Choose a font size")
        }
        .frame(height: 26)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isEditing ? Color.accentColor : Color.secondary.opacity(0.35))
                .allowsHitTesting(false)
        }
    }

    private func submit() {
        guard let draft else { return }
        guard let points = try? Double(draft.trimmingCharacters(in: .whitespaces),
                                       format: numberFormat, lenient: false),
              (1...1638).contains(points) else {
            NSSound.beep()
            self.draft = nil
            return
        }
        self.draft = nil
        // Word stores font sizes in half points.
        apply(CGFloat((points * 2).rounded() / 2))
    }
}
