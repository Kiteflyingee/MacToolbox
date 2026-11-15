import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, arguments[1].hasPrefix("local.mactoolbox.smoke") else {
    fatalError("Usage: pasteboard_fixture.swift local.mactoolbox.smoke[.suffix] <text|--read>")
}
let board = NSPasteboard(name: .init(arguments[1]))
if arguments[2] == "--read" {
    print(board.string(forType: .string) ?? "")
} else if arguments[2] == "--image-info" {
    guard let png = board.data(forType: .png),let image = NSBitmapImageRep(data: png) else { fatalError("No image on the isolated test board") }
    print("PNG \(image.pixelsWide) × \(image.pixelsHigh), \(png.count) bytes")
} else {
    board.clearContents()
    guard board.setString(arguments[2], forType: .string) else { fatalError("Private pasteboard write failed") }
    print("Wrote isolated test board")
}
