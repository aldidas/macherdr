import Foundation

struct LightTerminalANSIAdapter {
    private var pending: [UInt8] = []

    mutating func transform(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        pending.append(contentsOf: bytes)
        var output: [UInt8] = []
        output.reserveCapacity(pending.count)
        let consumed = pending.withUnsafeBufferPointer { buffer in
            Self.transform(buffer, into: &output)
        }
        if consumed > 0 {
            pending.removeFirst(consumed)
        }
        return output
    }

    /// Returns how many bytes of `buffer` were consumed; the rest is an
    /// incomplete sequence the caller must retain for the next feed.
    private static func transform(_ buffer: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) -> Int {
        let count = buffer.count
        guard let base = buffer.baseAddress else { return 0 }
        var index = 0

        while index < count {
            // Copy the run up to the next ESC in one go: most output is text.
            guard let escape = memchr(base + index, 0x1B, count - index) else {
                output.append(contentsOf: UnsafeBufferPointer(start: base + index, count: count - index))
                return count
            }
            let escapeIndex = base.distance(to: escape.assumingMemoryBound(to: UInt8.self))
            if escapeIndex > index {
                output.append(contentsOf: UnsafeBufferPointer(start: base + index, count: escapeIndex - index))
                index = escapeIndex
            }
            guard index + 1 < count else { break }
            guard buffer[index + 1] == 0x5B else {
                output.append(0x1B)
                index += 1
                continue
            }

            var end = index + 2
            while end < count, !(0x40...0x7E).contains(buffer[end]) {
                end += 1
            }
            guard end < count else { break }

            let sequence = UnsafeBufferPointer(rebasing: buffer[index...end])
            guard buffer[end] == 0x6D else {
                output.append(contentsOf: sequence)
                index = end + 1
                continue
            }

            let parameters = UnsafeBufferPointer(rebasing: buffer[(index + 2)..<end])
            let colors = colorIntroducers(in: parameters)
            if !colors.has38, !colors.has48 {
                // No 38/48 token: the transform is the identity.
                output.append(contentsOf: sequence)
                index = end + 1
                continue
            }
            // A Powerline separator is a foreground-colored shape painted
            // over the next segment's background.  Its foreground is not
            // ordinary text: it is deliberately the previous segment's
            // background.  Wait for the next scalar so the light-theme
            // contrast transform does not turn that join into a dark,
            // blended-looking arrow.
            //
            // Only a foreground SGR (38) can be the color of a following
            // separator, so only it is held back at the end of a PTY read;
            // otherwise typed echo can inherit the previous cell's style
            // until another output arrives.
            var preservesPowerlineForeground = false
            if colors.has38 {
                guard let follows = powerlineFollowsSGR(in: buffer, after: end + 1) else { break }
                preservesPowerlineForeground = follows
            }
            transformSGR(parameters, preservePowerlineForeground: preservesPowerlineForeground, into: &output)
            index = end + 1
        }
        return index
    }

    /// WCAG contrast ratio of an sRGB color against a white background.
    static func contrastOnWhite(red: Int, green: Int, blue: Int) -> Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }

    static func lightRGB(red: Int, green: Int, blue: Int) -> (red: Int, green: Int, blue: Int) {
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        let offset = 255 - 2 * luminance
        return (
            clamp(Double(red) + offset),
            clamp(Double(green) + offset),
            clamp(Double(blue) + offset)
        )
    }

    /// Adapts one color for the light theme.
    ///
    /// Backgrounds flip only when they are dark: the adapter's job is "make
    /// this output suit a light terminal", and a light background already
    /// does. Flipping unconditionally double-inverted agents that are
    /// themselves in a light theme — Claude Code's pale user-message bar
    /// became a black strip, and since the foreground rule keeps dark text
    /// dark, the result was dark-on-black. Dark-themed output (Codex's
    /// `48;2;30;30;30` box, 256-color dark diff backgrounds) still flips.
    ///
    /// Foregrounds keep whichever variant reads better on white — same rule
    /// as the ANSI palette, so an already-dark foreground (diff red, syntax
    /// blue) doesn't wash out to a pastel.
    static func adapt(red: Int, green: Int, blue: Int, isBackground: Bool) -> (red: Int, green: Int, blue: Int) {
        let flipped = lightRGB(red: red, green: green, blue: blue)
        if isBackground {
            let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
            return luminance < 128 ? flipped : (red, green, blue)
        }
        let originalContrast = contrastOnWhite(red: red, green: green, blue: blue)
        let flippedContrast = contrastOnWhite(red: flipped.red, green: flipped.green, blue: flipped.blue)
        return originalContrast >= flippedContrast ? (red, green, blue) : flipped
    }

    /// The standard xterm 256-color palette above the 16 ANSI entries:
    /// 16–231 form a 6×6×6 cube, 232–255 a grayscale ramp.
    static func xterm256RGB(_ index: Int) -> (red: Int, green: Int, blue: Int) {
        if index >= 232 {
            let gray = 8 + 10 * (index - 232)
            return (gray, gray, gray)
        }
        let levels = [0, 95, 135, 175, 215, 255]
        let value = index - 16
        return (levels[value / 36], levels[(value / 6) % 6], levels[value % 6])
    }

    /// Whether the parameter list holds a `38` or `48` token.
    private static func colorIntroducers(in parameters: UnsafeBufferPointer<UInt8>) -> (has38: Bool, has48: Bool) {
        var has38 = false
        var has48 = false
        var cursor = TokenCursor(parameters)
        while let token = cursor.next() {
            if token.count == 2, parameters[token.lowerBound + 1] == 0x38 {
                switch parameters[token.lowerBound] {
                case 0x33: has38 = true
                case 0x34: has48 = true
                default: break
                }
            }
        }
        return (has38, has48)
    }

    /// Looks past complete control sequences for the next UTF-8 scalar.
    /// `nil` means that the current chunk ends before the scalar (or its
    /// intervening CSI), so the caller must retain the SGR for the next feed.
    private static func powerlineFollowsSGR(in buffer: UnsafeBufferPointer<UInt8>, after start: Int) -> Bool? {
        var index = start
        while index < buffer.count {
            // SGRs are sometimes split into separate writes by a prompt
            // renderer. Skip a complete CSI while looking for the glyph.
            if buffer[index] == 0x1B {
                guard index + 1 < buffer.count else { return nil }
                guard buffer[index + 1] == 0x5B else { return false }
                var end = index + 2
                while end < buffer.count, !(0x40...0x7E).contains(buffer[end]) {
                    end += 1
                }
                guard end < buffer.count else { return nil }
                index = end + 1
                continue
            }

            // Do not classify an incomplete UTF-8 sequence as an ordinary
            // character: dataReceived can split the glyph across chunks.
            let first = buffer[index]
            let scalarLength: Int
            switch first {
            case 0xC2...0xDF: scalarLength = 2
            case 0xE0...0xEF: scalarLength = 3
            case 0xF0...0xF4: scalarLength = 4
            default:
                return false
            }
            guard index + scalarLength <= buffer.count else { return nil }
            // Include the thin and rounded Powerline variants as well as the
            // four shapes the renderer draws itself (U+E0B0...U+E0D7, encoded
            // EE 82 B0...EE 83 97). All of them use the same
            // foreground/background layering contract. Malformed bytes decode
            // to U+FFFD, which is outside the range.
            guard scalarLength == 3, first == 0xEE else { return false }
            let second = buffer[index + 1]
            let third = buffer[index + 2]
            if second == 0x82 { return (0xB0...0xBF).contains(third) }
            if second == 0x83 { return (0x80...0x97).contains(third) }
            return false
        }
        return nil
    }

    /// Rewrites one SGR's colors for the light theme. `parameters` is the
    /// text between `ESC [` and `m`; tokens are `;`-separated, empty ones kept.
    private static func transformSGR(
        _ parameters: UnsafeBufferPointer<UInt8>,
        preservePowerlineForeground: Bool,
        into output: inout [UInt8]
    ) {
        output.append(0x1B)
        output.append(0x5B)
        var cursor = TokenCursor(parameters)
        var first = true

        func separate() {
            if !first { output.append(0x3B) }
            first = false
        }
        func emit(_ token: Range<Int>) {
            separate()
            output.append(contentsOf: UnsafeBufferPointer(rebasing: parameters[token]))
        }
        func emit(number: Int) {
            separate()
            if number >= 100 { output.append(UInt8(0x30 + number / 100)) }
            if number >= 10 { output.append(UInt8(0x30 + (number / 10) % 10)) }
            output.append(UInt8(0x30 + number % 10))
        }

        while let token = cursor.next() {
            let isColor = token.count == 2 && parameters[token.lowerBound + 1] == 0x38
                && (parameters[token.lowerBound] == 0x33 || parameters[token.lowerBound] == 0x34)
            guard isColor else {
                emit(token)
                continue
            }
            let isBackground = parameters[token.lowerBound] == 0x34
            let light = { (red: Int, green: Int, blue: Int) in
                preservePowerlineForeground && !isBackground
                    // Separator foregrounds are neighboring backgrounds, so
                    // use the background transform rather than the text
                    // contrast transform. This also keeps dark prompts
                    // internally consistent after their backgrounds flip.
                    ? adapt(red: red, green: green, blue: blue, isBackground: true)
                    : adapt(red: red, green: green, blue: blue, isBackground: isBackground)
            }

            var lookahead = cursor
            if let mode = lookahead.next() {
                if mode.count == 1, parameters[mode.lowerBound] == 0x32,
                   let red = lookahead.nextInt(), let green = lookahead.nextInt(), let blue = lookahead.nextInt(),
                   (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) {
                    let adapted = light(red, green, blue)
                    emit(token)
                    emit(number: 2)
                    emit(number: adapted.red)
                    emit(number: adapted.green)
                    emit(number: adapted.blue)
                    cursor = lookahead
                    continue
                }
                var palette = cursor
                _ = palette.next()
                // 0–15 resolve through the installed ANSI palette, which is
                // already themed; rewriting them here would flip them twice.
                if mode.count == 1, parameters[mode.lowerBound] == 0x35,
                   let paletteIndex = palette.nextInt(), (16...255).contains(paletteIndex) {
                    let base = xterm256RGB(paletteIndex)
                    let adapted = light(base.red, base.green, base.blue)
                    emit(token)
                    emit(number: 2)
                    emit(number: adapted.red)
                    emit(number: adapted.green)
                    emit(number: adapted.blue)
                    cursor = palette
                    continue
                }
            }
            emit(token)
        }
        output.append(0x6D)
    }

    /// Walks the `;`-separated tokens of an SGR parameter list, yielding
    /// `String.split(omittingEmptySubsequences: false)` semantics: an empty
    /// list is one empty token and a trailing `;` adds a final empty one.
    private struct TokenCursor {
        private let bytes: UnsafeBufferPointer<UInt8>
        private var position = 0
        private var finished = false

        init(_ bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        mutating func next() -> Range<Int>? {
            guard !finished else { return nil }
            var end = position
            while end < bytes.count, bytes[end] != 0x3B { end += 1 }
            let token = position..<end
            if end == bytes.count {
                finished = true
            } else {
                position = end + 1
            }
            return token
        }

        /// The next token as an `Int`, with `Int(String)` semantics, or nil
        /// when there is none or it does not parse.
        mutating func nextInt() -> Int? {
            guard let token = next() else { return nil }
            var index = token.lowerBound
            var negative = false
            if index < token.upperBound, bytes[index] == 0x2B || bytes[index] == 0x2D {
                negative = bytes[index] == 0x2D
                index += 1
            }
            guard index < token.upperBound else { return nil }
            var value = 0
            while index < token.upperBound {
                let digit = Int(bytes[index]) - 0x30
                guard (0...9).contains(digit) else { return nil }
                let (scaled, overflowMul) = value.multipliedReportingOverflow(by: 10)
                let (sum, overflowAdd) = scaled.addingReportingOverflow(negative ? -digit : digit)
                if overflowMul || overflowAdd { return nil }
                value = sum
                index += 1
            }
            return value
        }
    }

    private static func clamp(_ value: Double) -> Int {
        min(255, max(0, Int(value.rounded())))
    }
}
