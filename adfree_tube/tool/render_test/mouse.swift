// Moves and clicks the real mouse on the CI Mac, for the macOS user test
// (user_drive.py). Coordinates are points from the top left of the main
// display, the same as window bounds.
//   mouse window <app name>       prints the app's window: x y w h
//   mouse move <x> <y>
//   mouse click <x> <y>
//   mouse drag <x1> <y1> <x2> <y2>   presses at 1, moves to 2 over ~1 s
import CoreGraphics
import Foundation

func post(_ type: CGEventType, _ x: Double, _ y: Double) {
  let e = CGEvent(mouseEventSource: nil, mouseType: type,
                  mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
  e?.post(tap: .cghidEventTap)
}

let a = CommandLine.arguments
func num(_ i: Int) -> Double { Double(a[i]) ?? 0 }

switch a.count > 1 ? a[1] : "" {
case "window":
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                        kCGNullWindowID) as? [[String: Any]] ?? []
  // The app's biggest normal window.
  let best = list
    .filter { ($0[kCGWindowOwnerName as String] as? String) == a[2]
              && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .compactMap { $0[kCGWindowBounds as String] as? [String: Double] }
    .max { ($0["Width"]! * $0["Height"]!) < ($1["Width"]! * $1["Height"]!) }
  guard let b = best else { print("none"); exit(1) }
  print(b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
case "move":
  post(.mouseMoved, num(2), num(3))
case "click":
  post(.mouseMoved, num(2), num(3))
  usleep(100_000)
  post(.leftMouseDown, num(2), num(3))
  usleep(80_000)
  post(.leftMouseUp, num(2), num(3))
case "drag":
  let (x1, y1, x2, y2) = (num(2), num(3), num(4), num(5))
  post(.mouseMoved, x1, y1)
  usleep(100_000)
  post(.leftMouseDown, x1, y1)
  let steps = 25
  for i in 1...steps {
    usleep(40_000)
    let f = Double(i) / Double(steps)
    post(.leftMouseDragged, x1 + (x2 - x1) * f, y1 + (y2 - y1) * f)
  }
  usleep(150_000)
  post(.leftMouseUp, x2, y2)
default:
  FileHandle.standardError.write("usage: mouse window|move|click|drag ...\n".data(using: .utf8)!)
  exit(2)
}
