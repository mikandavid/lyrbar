import AppKit

/// A labelled slider packaged as an NSMenuItem.view, with live + commit callbacks.
final class SliderItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let format: (Double) -> String
    var onChange: ((Double) -> Void)?

    init(title: String, range: ClosedRange<Double>, value: Double, width: CGFloat = 260,
         format: @escaping (Double) -> String) {
        self.format = format
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        updateTitle(title)
        baseTitle = title
    }
    required init?(coder: NSCoder) { fatalError() }

    private var baseTitle = ""
    private func updateTitle(_ base: String) {
        titleLabel.stringValue = "\(base): \(format(slider.doubleValue))"
    }

    @objc private func changed() {
        updateTitle(baseTitle)
        onChange?(slider.doubleValue)
    }

    func setValue(_ v: Double) {
        slider.doubleValue = v
        updateTitle(baseTitle)
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue; titleLabel.textColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor }
    }
}
