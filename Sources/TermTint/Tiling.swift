import CoreGraphics
import Foundation

/// Lays windows out side by side.
enum Tiling {

    /// Splits an area into `count` non-overlapping rectangles that use all of
    /// it. The number of rows is chosen so the cells come out roughly as wide
    /// as a terminal wants to be; a count that does not divide evenly puts the
    /// extra windows in the upper rows, and every row still spans the full
    /// width, so nothing is left blank.
    static func grid(count: Int, in area: CGRect, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0, area.width > 0, area.height > 0 else { return [] }

        let target: CGFloat = 1.45
        var rows = 1
        var best = CGFloat.greatestFiniteMagnitude
        for candidate in 1...count {
            let columns = Int(ceil(Double(count) / Double(candidate)))
            let cell = (area.width / CGFloat(columns)) / (area.height / CGFloat(candidate))
            let score = abs(log(cell / target))
            if score < best {
                best = score
                rows = candidate
            }
        }

        // Spread the windows over the rows, fullest first.
        var perRow = Array(repeating: count / rows, count: rows)
        for index in 0..<(count % rows) { perRow[index] += 1 }

        var result: [CGRect] = []
        let rowHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (rowIndex, columns) in perRow.enumerated() where columns > 0 {
            let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            // Rows are filled from the top, and Cocoa counts from the bottom.
            let y = area.maxY - CGFloat(rowIndex + 1) * rowHeight - CGFloat(rowIndex) * gap
            for column in 0..<columns {
                result.append(CGRect(x: area.minX + CGFloat(column) * (width + gap),
                                     y: y, width: width, height: rowHeight))
            }
        }
        return result
    }
}

/// A change to every window's geometry that can be taken back again. Pressing
/// the same button twice puts the windows back where they were, which matters
/// because these actions move everything at once.
enum Arrangement: Hashable {
    /// All visible windows spread over one screen.
    case tileAll
    /// The marked ones to the front, side by side.
    case tileMarked
    /// Every window back to the size a new one would have.
    case defaultSize
}
