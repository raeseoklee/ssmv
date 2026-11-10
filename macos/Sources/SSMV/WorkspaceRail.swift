import AppKit

/// Persistent workspace actions, including when the document sidebar is collapsed.
@MainActor
final class WorkspaceRail: NSView {
  var onSidebar: (() -> Void)?
  var onFind: (() -> Void)?
  var onOutline: (() -> Void)?

  private var sidebarShown = true
  private var outlineShown = false
  private let sidebar = NSButton()
  private let find = NSButton()
  var searchAnchor: NSView { find }
  private let outline = NSButton()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let background = NSVisualEffectView()
    background.material = .sidebar
    background.blendingMode = .withinWindow
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)

    configure(sidebar, symbol: "sidebar.left", label: "Documents sidebar", action: #selector(toggleSidebar))
    configure(find, symbol: "magnifyingglass", label: "Search documents", action: #selector(findText))
    configure(outline, symbol: "list.bullet.indent", label: "Document outline", action: #selector(toggleOutline))
    find.toolTip = "Search documents by name or content"

    let stack = NSStackView(views: [sidebar, outline])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    find.translatesAutoresizingMaskIntoConstraints = false
    addSubview(find)
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    addSubview(divider)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 40),
      background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
      background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      find.centerXAnchor.constraint(equalTo: centerXAnchor), find.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor), divider.topAnchor.constraint(equalTo: topAnchor),
      divider.bottomAnchor.constraint(equalTo: bottomAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
    ])
    update(sidebarVisible: true, outlineVisible: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func update(sidebarVisible: Bool, outlineVisible: Bool) {
    sidebarShown = sidebarVisible
    outlineShown = outlineVisible
    setToggle(sidebar, active: sidebarVisible, tooltip: sidebarVisible ? "Hide Documents Sidebar" : "Show Documents Sidebar")
    setToggle(outline, active: outlineVisible, tooltip: outlineVisible ? "Hide Document Outline" : "Show Document Outline")
  }

  private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
    button.title = ""
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
    button.imagePosition = .imageOnly
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.focusRingType = .default
    button.target = self
    button.action = action
    button.setAccessibilityLabel(label)
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    button.contentTintColor = .secondaryLabelColor
    button.wantsLayer = true
    button.layer?.cornerRadius = 5
  }

  private func setToggle(_ button: NSButton, active: Bool, tooltip: String) {
    button.toolTip = tooltip
    button.setAccessibilityRole(.checkBox)
    button.setAccessibilityValue(NSNumber(value: active))
    button.contentTintColor = active ? .labelColor : .secondaryLabelColor
    button.layer?.borderWidth = active ? 1 : 0
    effectiveAppearance.performAsCurrentDrawingAppearance {
      button.layer?.borderColor = NSColor.separatorColor.cgColor
      button.layer?.backgroundColor = active ? NSColor.quaternaryLabelColor.cgColor : nil
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    update(sidebarVisible: sidebarShown, outlineVisible: outlineShown)
  }

  @objc private func toggleSidebar() { onSidebar?() }
  @objc private func findText() { onFind?() }
  @objc private func toggleOutline() { onOutline?() }
}
