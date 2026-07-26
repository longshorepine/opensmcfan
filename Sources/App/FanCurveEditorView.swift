import AppKit

// MARK: - Fan Curve Editor Delegate

protocol FanCurveEditorDelegate: AnyObject {
    /// Called whenever a control point is moved, added, or removed.
    func fanCurveEditorDidChange(_ editor: FanCurveEditorView, curve: FanCurve)
}

// MARK: - Fan Curve Editor View

/// Custom NSView: interactive temperature-vs-RPM curve editor.
/// Draws a grid, colored temperature zones, piecewise-linear curve,
/// draggable control points, and live temp/RPM crosshairs.
final class FanCurveEditorView: NSView {
    weak var delegate: FanCurveEditorDelegate?

    // Identity
    var fanIndex: Int = 0

    // Data
    var curve: FanCurve = FanCurve(points: []) {
        didSet { needsDisplay = true }
    }

    var minRPM: Double = 0
    var maxRPM: Double = 6500 {
        didSet { needsDisplay = true }
    }

    // Live sensor values (updated by preferences controller)
    var liveTemperature: Double? {
        didSet { needsDisplay = true }
    }
    var liveRPM: Double? {
        didSet { needsDisplay = true }
    }

    // Axis range
    private let tempMin: Double = 20
    private let tempMax: Double = 105

    // Graph insets (space for axis labels)
    private let insetLeft: CGFloat = 44
    private let insetRight: CGFloat = 12
    private let insetTop: CGFloat = 12
    private let insetBottom: CGFloat = 28

    // Interaction
    private var dragIndex: Int?
    private let hitRadius: CGFloat = 10
    private let pointRadius: CGFloat = 5

    // MARK: - Drawing

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let graphRect = self.graphRect

        // Background
        NSColor.controlBackgroundColor.setFill()
        ctx.fill(bounds)

        // Temperature zones
        drawTemperatureZones(in: graphRect)

        // Grid
        drawGrid(in: graphRect)

        // Curve line
        drawCurve(in: graphRect)

        // Control points
        drawControlPoints(in: graphRect)

        // Live crosshairs
        drawCrosshairs(in: graphRect)

        // Axis labels
        drawAxisLabels(in: graphRect)

        // Border
        NSColor.separatorColor.setStroke()
        let borderPath = NSBezierPath(rect: graphRect)
        borderPath.lineWidth = 1
        borderPath.stroke()
    }

    private var graphRect: NSRect {
        NSRect(
            x: insetLeft,
            y: insetBottom,
            width: bounds.width - insetLeft - insetRight,
            height: bounds.height - insetTop - insetBottom
        )
    }

    // MARK: - Temperature Zones

    private func drawTemperatureZones(in rect: NSRect) {
        let zones: [(Double, Double, NSColor)] = [
            (tempMin, 60, NSColor.systemGreen.withAlphaComponent(0.08)),
            (60,      75, NSColor.systemYellow.withAlphaComponent(0.08)),
            (75,      90, NSColor.systemOrange.withAlphaComponent(0.08)),
            (90, tempMax, NSColor.systemRed.withAlphaComponent(0.08)),
        ]

        for (lo, hi, color) in zones {
            let x1 = tempToX(lo, in: rect)
            let x2 = tempToX(hi, in: rect)
            let zoneRect = NSRect(x: x1, y: rect.minY, width: x2 - x1, height: rect.height)
            color.setFill()
            zoneRect.fill()
        }
    }

    // MARK: - Grid

    private func drawGrid(in rect: NSRect) {
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.3)
        gridColor.setStroke()

        let gridPath = NSBezierPath()
        gridPath.lineWidth = 0.5

        // Vertical lines every 10 degrees
        var temp = ceil(tempMin / 10) * 10
        while temp <= tempMax {
            let x = tempToX(temp, in: rect)
            gridPath.move(to: NSPoint(x: x, y: rect.minY))
            gridPath.line(to: NSPoint(x: x, y: rect.maxY))
            temp += 10
        }

        // Horizontal lines every 1000 RPM
        var rpm = ceil(minRPM / 1000) * 1000
        while rpm <= maxRPM {
            let y = rpmToY(rpm, in: rect)
            gridPath.move(to: NSPoint(x: rect.minX, y: y))
            gridPath.line(to: NSPoint(x: rect.maxX, y: y))
            rpm += 1000
        }

        gridPath.stroke()
    }

    // MARK: - Curve Line

    private func drawCurve(in rect: NSRect) {
        guard curve.points.count >= 2 else { return }

        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // Extend flat to left edge
        let firstPt = curve.points[0]
        path.move(to: NSPoint(x: rect.minX, y: rpmToY(firstPt.rpm, in: rect)))

        for point in curve.points {
            let pt = NSPoint(x: tempToX(point.temperature, in: rect),
                             y: rpmToY(point.rpm, in: rect))
            path.line(to: pt)
        }

        // Extend flat to right edge
        let lastPt = curve.points[curve.points.count - 1]
        path.line(to: NSPoint(x: rect.maxX, y: rpmToY(lastPt.rpm, in: rect)))

        NSColor.systemBlue.setStroke()
        path.stroke()
    }

    // MARK: - Control Points

    private func drawControlPoints(in rect: NSRect) {
        for (i, point) in curve.points.enumerated() {
            let center = NSPoint(x: tempToX(point.temperature, in: rect),
                                 y: rpmToY(point.rpm, in: rect))

            let isDragging = dragIndex == i
            let radius = isDragging ? pointRadius + 2 : pointRadius

            let circle = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))

            (isDragging ? NSColor.systemBlue : NSColor.white).setFill()
            circle.fill()
            NSColor.systemBlue.setStroke()
            circle.lineWidth = 2
            circle.stroke()

            // Label: "65°C / 3200"
            let label = String(format: "%.0f\u{00B0}/%.0f", point.temperature, point.rpm)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let labelPt = NSPoint(x: center.x - size.width / 2,
                                  y: center.y + radius + 3)
            (label as NSString).draw(at: labelPt, withAttributes: attrs)
        }
    }

    // MARK: - Live Crosshairs

    private func drawCrosshairs(in rect: NSRect) {
        let dashPattern: [CGFloat] = [4, 3]

        if let temp = liveTemperature {
            let x = tempToX(temp, in: rect)
            guard x >= rect.minX && x <= rect.maxX else { return }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
            path.lineWidth = 1
            path.setLineDash(dashPattern, count: 2, phase: 0)
            NSColor.systemRed.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }

        if let rpm = liveRPM {
            let y = rpmToY(rpm, in: rect)
            guard y >= rect.minY && y <= rect.maxY else { return }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            path.lineWidth = 1
            path.setLineDash(dashPattern, count: 2, phase: 0)
            NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }
    }

    // MARK: - Axis Labels

    private func drawAxisLabels(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Temperature axis (bottom)
        var temp = ceil(tempMin / 10) * 10
        while temp <= tempMax {
            let x = tempToX(temp, in: rect)
            let label = "\(Int(temp))\u{00B0}"
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: NSPoint(x: x - size.width / 2, y: rect.minY - size.height - 2),
                withAttributes: attrs
            )
            temp += 10
        }

        // RPM axis (left)
        var rpm = ceil(minRPM / 1000) * 1000
        while rpm <= maxRPM {
            let y = rpmToY(rpm, in: rect)
            let label = "\(Int(rpm))"
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: NSPoint(x: rect.minX - size.width - 4, y: y - size.height / 2),
                withAttributes: attrs
            )
            rpm += 1000
        }
    }

    // MARK: - Coordinate Mapping

    private func tempToX(_ temp: Double, in rect: NSRect) -> CGFloat {
        let fraction = CGFloat((temp - tempMin) / (tempMax - tempMin))
        return rect.minX + fraction * rect.width
    }

    private func rpmToY(_ rpm: Double, in rect: NSRect) -> CGFloat {
        let rpmRange = maxRPM - minRPM
        guard rpmRange > 0 else { return rect.minY }
        let fraction = CGFloat((rpm - minRPM) / rpmRange)
        return rect.minY + fraction * rect.height
    }

    private func xToTemp(_ x: CGFloat, in rect: NSRect) -> Double {
        let fraction = Double((x - rect.minX) / rect.width)
        return tempMin + fraction * (tempMax - tempMin)
    }

    private func yToRPM(_ y: CGFloat, in rect: NSRect) -> Double {
        let fraction = Double((y - rect.minY) / rect.height)
        return minRPM + fraction * (maxRPM - minRPM)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let rect = graphRect

        // Check double-click: add new point
        if event.clickCount == 2 {
            let temp = xToTemp(loc.x, in: rect)
            let rpm = yToRPM(loc.y, in: rect)
            let clampedTemp = min(max(temp, tempMin), tempMax)
            let clampedRPM = min(max(rpm, minRPM), maxRPM)

            guard curve.points.count < 8 else { return }
            curve.points.append(FanCurvePoint(temperature: clampedTemp, rpm: clampedRPM))
            curve.points.sort(by: { $0.temperature < $1.temperature })
            delegate?.fanCurveEditorDidChange(self, curve: curve)
            needsDisplay = true
            return
        }

        // Hit-test existing points
        dragIndex = nil
        for (i, point) in curve.points.enumerated() {
            let center = NSPoint(x: tempToX(point.temperature, in: rect),
                                 y: rpmToY(point.rpm, in: rect))
            let dx = loc.x - center.x
            let dy = loc.y - center.y
            if sqrt(dx * dx + dy * dy) < hitRadius {
                dragIndex = i
                needsDisplay = true
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let idx = dragIndex else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let rect = graphRect

        var temp = xToTemp(loc.x, in: rect)
        var rpm = yToRPM(loc.y, in: rect)

        // Clamp to graph bounds
        temp = min(max(temp, tempMin), tempMax)
        rpm = min(max(rpm, minRPM), maxRPM)

        curve.points[idx] = FanCurvePoint(temperature: temp, rpm: rpm)
        delegate?.fanCurveEditorDidChange(self, curve: curve)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragIndex != nil {
            // Sort points after drag finishes
            curve.points.sort(by: { $0.temperature < $1.temperature })
            delegate?.fanCurveEditorDidChange(self, curve: curve)
            dragIndex = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard curve.points.count > 2 else { return }  // keep at least 2 points

        let loc = convert(event.locationInWindow, from: nil)
        let rect = graphRect

        for (i, point) in curve.points.enumerated() {
            let center = NSPoint(x: tempToX(point.temperature, in: rect),
                                 y: rpmToY(point.rpm, in: rect))
            let dx = loc.x - center.x
            let dy = loc.y - center.y
            if sqrt(dx * dx + dy * dy) < hitRadius {
                curve.points.remove(at: i)
                delegate?.fanCurveEditorDidChange(self, curve: curve)
                needsDisplay = true
                return
            }
        }
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        NSSize(width: 400, height: 200)
    }
}
