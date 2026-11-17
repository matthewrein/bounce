import Foundation

/// A 2-D point or vector (image pixels unless stated otherwise).
public struct Vec2: Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public func dot(_ b: Vec2) -> Double { x * b.x + y * b.y }
    /// z of the 3-D cross product (positive when b is counter-clockwise from self in a y-up frame)
    public func cross(_ b: Vec2) -> Double { x * b.y - y * b.x }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 { let l = length; return l > 0 ? self / l : self }
    /// rotated +90 degrees: (x, y) -> (-y, x)
    public var perpendicular: Vec2 { Vec2(-y, x) }
    public func distance(to b: Vec2) -> Double { (self - b).length }
    public var description: String { String(format: "(%.2f, %.2f)", x, y) }
}

/// A 3-D point or vector.
public struct Vec3: Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public init(_ a: [Double]) { precondition(a.count == 3); self.init(a[0], a[1], a[2]) }
    public static let zero = Vec3(0, 0, 0)
    public var array: [Double] { [x, y, z] }
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    public static func -= (a: inout Vec3, b: Vec3) { a = a - b }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var lengthSquared: Double { x * x + y * y + z * z }
    /// unit vector (the zero vector stays zero)
    public var normalized: Vec3 { let l = length; return l > 0 ? self / l : self }
    public func distance(to b: Vec3) -> Double { (self - b).length }
    /// angle to another vector, radians
    public func angle(to b: Vec3) -> Double {
        let d = normalized.dot(b.normalized)
        return acos(max(-1, min(1, d)))
    }
    /// the part of self perpendicular to a unit vector u
    public func rejecting(_ u: Vec3) -> Vec3 { self - u * dot(u) }
    /// rotate by a rotation vector w (axis * angle, radians), Rodrigues' formula
    public func rotated(by w: Vec3) -> Vec3 {
        let th = w.length
        if th < 1e-12 { return self }
        let k = w / th, c = cos(th), s = sin(th)
        return self * c + k.cross(self) * s + k * (k.dot(self) * (1 - c))
    }
    /// any unit vector perpendicular to self (self need not be unit)
    public var anyPerpendicular: Vec3 {
        let a = abs(x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        return cross(a).normalized
    }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public var description: String { String(format: "(%.4f, %.4f, %.4f)", x, y, z) }
}

/// A 3x3 matrix stored by rows.
public struct Mat3: Equatable, Codable {
    public var m: [Double] // 9 values, row-major
    public init(rows: [Double]) { precondition(rows.count == 9); m = rows }
    public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        m = [c0.x, c1.x, c2.x, c0.y, c1.y, c2.y, c0.z, c1.z, c2.z]
    }
    public static let identity = Mat3(rows: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    public subscript(r: Int, c: Int) -> Double {
        get { m[r * 3 + c] }
        set { m[r * 3 + c] = newValue }
    }
    public func column(_ c: Int) -> Vec3 { Vec3(m[c], m[3 + c], m[6 + c]) }
    public func row(_ r: Int) -> Vec3 { Vec3(m[r * 3], m[r * 3 + 1], m[r * 3 + 2]) }
    public var transposed: Mat3 { Mat3(rows: [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]) }
    public static func * (a: Mat3, v: Vec3) -> Vec3 { Vec3(a.row(0).dot(v), a.row(1).dot(v), a.row(2).dot(v)) }
    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { var s = 0.0; for k in 0..<3 { s += a[i, k] * b[k, j] }; r[i * 3 + j] = s } }
        return Mat3(rows: r)
    }
    public var determinant: Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }
    public var inverse: Mat3? {
        let d = determinant
        if abs(d) < 1e-15 { return nil }
        let i = 1 / d
        return Mat3(rows: [
            (m[4] * m[8] - m[5] * m[7]) * i, (m[2] * m[7] - m[1] * m[8]) * i, (m[1] * m[5] - m[2] * m[4]) * i,
            (m[5] * m[6] - m[3] * m[8]) * i, (m[0] * m[8] - m[2] * m[6]) * i, (m[2] * m[3] - m[0] * m[5]) * i,
            (m[3] * m[7] - m[4] * m[6]) * i, (m[1] * m[6] - m[0] * m[7]) * i, (m[0] * m[4] - m[1] * m[3]) * i,
        ])
    }
}

/// A rigid transform: p_out = rotation * p_in + translation.
public struct RigidTransform: Equatable, Codable {
    public var rotation: Mat3
    public var translation: Vec3
    public init(rotation: Mat3, translation: Vec3) { self.rotation = rotation; self.translation = translation }
    public static let identity = RigidTransform(rotation: .identity, translation: .zero)
    public func apply(_ p: Vec3) -> Vec3 { rotation * p + translation }
    public func applyDirection(_ v: Vec3) -> Vec3 { rotation * v }
    public var inverse: RigidTransform {
        let rt = rotation.transposed
        return RigidTransform(rotation: rt, translation: -(rt * translation))
    }
    public static func * (a: RigidTransform, b: RigidTransform) -> RigidTransform {
        RigidTransform(rotation: a.rotation * b.rotation, translation: a.rotation * b.translation + a.translation)
    }
    /// From a 4x4 column-major matrix (16 values, as simd_float4x4 is laid out: column 0 first).
    public init(columnMajor4x4 a: [Double]) {
        precondition(a.count == 16)
        rotation = Mat3(rows: [a[0], a[4], a[8], a[1], a[5], a[9], a[2], a[6], a[10]])
        translation = Vec3(a[12], a[13], a[14])
    }
    public var columnMajor4x4: [Double] {
        let r = rotation
        return [r[0, 0], r[1, 0], r[2, 0], 0, r[0, 1], r[1, 1], r[2, 1], 0, r[0, 2], r[1, 2], r[2, 2], 0,
                translation.x, translation.y, translation.z, 1]
    }
}

@inline(__always) public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(hi, max(lo, v)) }

/// Units: BounceCore works in metres and seconds; these convert the owner's units.
public enum Units {
    public static let metresPerInch = 0.0254
    public static let metresPerFoot = 0.3048
    public static let gravity = 9.80665 // m/s^2
    public static func inches(_ v: Double) -> Double { v * metresPerInch }
    public static func feet(_ v: Double) -> Double { v * metresPerFoot }
    public static func toInches(_ m: Double) -> Double { m / metresPerInch }
    public static func toFeet(_ m: Double) -> Double { m / metresPerFoot }
    public static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }
    public static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
}

/// Solve A x = b (n x n, row-major rows) by Gaussian elimination with partial pivoting. nil if singular.
public func solveLinear(_ Ain: [[Double]], _ bin: [Double]) -> [Double]? {
    var A = Ain, b = bin
    let n = b.count
    for i in 0..<n {
        var p = i
        for r in (i + 1)..<max(i + 1, n) where abs(A[r][i]) > abs(A[p][i]) { p = r }
        if abs(A[p][i]) < 1e-14 { return nil }
        if p != i { A.swapAt(i, p); b.swapAt(i, p) }
        for r in (i + 1)..<max(i + 1, n) {
            let f = A[r][i] / A[i][i]
            if f == 0 { continue }
            for c in i..<n { A[r][c] -= f * A[i][c] }
            b[r] -= f * b[i]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var s = b[i]
        for c in (i + 1)..<max(i + 1, n) { s -= A[i][c] * x[c] }
        x[i] = s / A[i][i]
    }
    return x
}
