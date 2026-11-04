import SwiftUI
import AppKit

/// Palette and metrics taken from the Rufus 3.20 window so the layout reads the same.
enum R {
    // surfaces
    static let bg          = Color(white: 1.0)
    static let field       = Color(white: 1.0)
    static let fieldOff    = Color(white: 0.945)
    static let statusBox   = Color(white: 0.968)
    static let bar         = Color(white: 0.937)

    // text
    static let text        = Color(white: 0.09)
    static let textOff     = Color(white: 0.55)
    static let label       = Color(white: 0.22)

    // lines
    static let border      = Color(white: 0.72)
    static let borderSoft  = Color(white: 0.80)
    static let rule        = Color(white: 0.76)
    static let divider     = Color(white: 0.86)

    // accents
    static let accent      = Color(red: 0.05, green: 0.38, blue: 0.75)
    static let accentSoft  = Color(red: 0.42, green: 0.66, blue: 0.88)

    // metrics
    static let fieldH: CGFloat = 26
    static let radius: CGFloat = 2
    static let pad: CGFloat = 16
}

// MARK: - Section header ("Drive Properties ───────")

struct RufusHeader: View {
    let text: String
    var body: some View {
        HStack(spacing: 9) {
            Text(text)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(R.text)
                .fixedSize()
            Rectangle()
                .fill(R.rule)
                .frame(height: 1)
                .padding(.top, 1)
        }
        .padding(.top, 2)
    }
}

// MARK: - Label + control stack

struct RufusField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(R.label)
            content
        }
    }
}

// MARK: - Combo box (field + separate arrow cell, like the Windows control)

/// SwiftUI's `Menu` refuses to render a custom label here (it falls back to the
/// "⌄ title" popup), so the field is a plain Button that pops a real NSMenu.
private final class ComboTarget: NSObject {
    var pick: ((Int) -> Void)?
    @objc func fire(_ sender: NSMenuItem) { pick?(sender.tag) }
}

struct RufusCombo<Item: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Item
    let items: [Item]
    let label: (Item) -> String
    var enabled: Bool = true
    var leadingSymbol: String? = nil
    var fixedWidth: CGFloat? = nil
    @ViewBuilder var extraMenu: () -> Content

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 0) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(enabled ? R.label : R.textOff)
                        .padding(.leading, 6)
                }
                Text(label(selection))
                    .font(.system(size: 12))
                    .foregroundStyle(enabled ? R.text : R.textOff)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(R.border)
                    .frame(width: 1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(enabled ? R.label : R.textOff)
                    .frame(width: 21)
            }
            .frame(width: fixedWidth, height: R.fieldH)
            .background(enabled ? R.field : R.fieldOff)
            .overlay(
                RoundedRectangle(cornerRadius: R.radius)
                    .strokeBorder(R.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func popUp() {
        let target = ComboTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, item) in items.enumerated() {
            let mi = NSMenuItem(title: label(item),
                                action: #selector(ComboTarget.fire(_:)),
                                keyEquivalent: "")
            mi.target = target
            mi.tag = i
            if item == selection { mi.state = .on }
            menu.addItem(mi)
        }
        target.pick = { i in
            guard items.indices.contains(i) else { return }
            selection = items[i]
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Checkbox (square, blue when checked)

struct RufusCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(configuration.isOn ? R.accent : R.field)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(configuration.isOn ? R.accent : R.border, lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                .offset(y: 1)

                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(R.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(configuration.isOn || true ? 1 : 1)
    }
}

// MARK: - Buttons

struct RufusButtonStyle: ButtonStyle {
    var width: CGFloat? = nil
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(prominent ? Color.white : R.accent)
            .padding(.horizontal, 12)
            .frame(width: width, height: 27)
            .background(prominent ? R.accent : R.field)
            .overlay(
                RoundedRectangle(cornerRadius: R.radius)
                    .strokeBorder(R.accent, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct RufusIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(R.accent)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Status readout

struct RufusStatusBox: View {
    let text: String
    let progress: Double
    let running: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(R.statusBox)
            if running {
                GeometryReader { geo in
                    Rectangle()
                        .fill(R.accentSoft.opacity(0.45))
                        .frame(width: max(2, geo.size.width * progress))
                }
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(R.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 8)
        }
        .frame(height: 54)
        .overlay(
            RoundedRectangle(cornerRadius: R.radius)
                .strokeBorder(R.border, lineWidth: 1)
        )
    }
}

// MARK: - Thin progress bar (the row above START / CLOSE)

struct RufusProgressBar: View {
    let progress: Double
    let running: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(R.fieldOff)
                Rectangle()
                    .fill(running ? R.accent : R.borderSoft)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 12)
        .overlay(
            RoundedRectangle(cornerRadius: R.radius)
                .strokeBorder(R.border, lineWidth: 1)
        )
    }
}

// MARK: - Disclosure row with chevron on the left

struct RufusDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(R.label)
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(R.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded { content }
        }
    }
}
