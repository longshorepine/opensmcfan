import Foundation

// MARK: - Fan Curve Point

/// A single control point on a temperature → RPM curve.
public struct FanCurvePoint: Codable, Equatable {
    public var temperature: Double  // °C
    public var rpm: Double          // RPM

    public init(temperature: Double, rpm: Double) {
        self.temperature = temperature
        self.rpm = rpm
    }
}

// MARK: - Fan Curve

/// Piecewise-linear mapping from temperature to target RPM.
///
/// Control points are always kept sorted by temperature.
/// Between points, RPM is linearly interpolated.
/// Below the first point, RPM stays at the first point's value.
/// Above the last point, RPM stays at the last point's value.
public struct FanCurve: Codable, Equatable {
    /// Control points (sorted by temperature).
    public var points: [FanCurvePoint] {
        didSet { points.sort(by: { $0.temperature < $1.temperature }) }
    }

    /// Temperature hysteresis in °C. Temp must drop this far below
    /// a ramp-down threshold before fan slows (prevents oscillation).
    public var hysteresis: Double

    /// Maximum RPM change per second (smooths transitions).
    public var rampRate: Double

    /// Seconds temperature must stay above a threshold before ramping
    /// (filters transient spikes).
    public var responseDelay: Double

    public init(
        points: [FanCurvePoint],
        hysteresis: Double = 3.0,
        rampRate: Double = 500.0,
        responseDelay: Double = 2.0
    ) {
        self.points = points.sorted(by: { $0.temperature < $1.temperature })
        self.hysteresis = hysteresis
        self.rampRate = rampRate
        self.responseDelay = responseDelay
    }

    /// Evaluate the curve at a given temperature → raw target RPM.
    /// Does NOT apply hysteresis or ramp rate (caller handles that).
    public func evaluate(at temperature: Double) -> Double {
        guard points.count >= 2 else {
            return points.first?.rpm ?? 0
        }

        // Below the lowest point
        if temperature <= points.first!.temperature {
            return points.first!.rpm
        }

        // Above the highest point
        if temperature >= points.last!.temperature {
            return points.last!.rpm
        }

        // Find bracketing points and interpolate
        for i in 0..<(points.count - 1) {
            let low = points[i]
            let high = points[i + 1]
            if temperature >= low.temperature && temperature <= high.temperature {
                let span = high.temperature - low.temperature
                guard span > 0 else { return low.rpm }
                let fraction = (temperature - low.temperature) / span
                return low.rpm + fraction * (high.rpm - low.rpm)
            }
        }

        return points.last!.rpm
    }

    // MARK: - Built-in curves

    /// Gentle ramp for quiet operation.
    public static func balanced(minRPM: Double, maxRPM: Double) -> FanCurve {
        FanCurve(points: [
            FanCurvePoint(temperature: 40, rpm: minRPM),
            FanCurvePoint(temperature: 55, rpm: minRPM + (maxRPM - minRPM) * 0.2),
            FanCurvePoint(temperature: 70, rpm: minRPM + (maxRPM - minRPM) * 0.5),
            FanCurvePoint(temperature: 80, rpm: minRPM + (maxRPM - minRPM) * 0.75),
            FanCurvePoint(temperature: 90, rpm: maxRPM),
        ], hysteresis: 3, rampRate: 400, responseDelay: 3)
    }

    /// Aggressive ramp for maximum cooling.
    public static func cool(minRPM: Double, maxRPM: Double) -> FanCurve {
        FanCurve(points: [
            FanCurvePoint(temperature: 35, rpm: minRPM + (maxRPM - minRPM) * 0.15),
            FanCurvePoint(temperature: 50, rpm: minRPM + (maxRPM - minRPM) * 0.4),
            FanCurvePoint(temperature: 65, rpm: minRPM + (maxRPM - minRPM) * 0.7),
            FanCurvePoint(temperature: 75, rpm: minRPM + (maxRPM - minRPM) * 0.9),
            FanCurvePoint(temperature: 85, rpm: maxRPM),
        ], hysteresis: 2, rampRate: 600, responseDelay: 1)
    }
}
