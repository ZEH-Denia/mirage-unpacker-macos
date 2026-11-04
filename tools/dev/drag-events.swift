import CoreGraphics
import Foundation
func event(_ type:CGEventType,_ x:Double,_ y:Double) { CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:x,y:y),mouseButton:.left)?.post(tap:.cghidEventTap) }
let values = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard values.count == 4 else { fatalError("usage: startX startY endX endY") }
let x1=values[0], y1=values[1], x2=values[2], y2=values[3]
event(.mouseMoved,x1,y1)
usleep(100000)
event(.leftMouseDown,x1,y1)
usleep(200000)
for i in 1...25 { let t=Double(i)/25; event(.leftMouseDragged,x1+(x2-x1)*t,y1+(y2-y1)*t); usleep(30000) }
usleep(300000)
event(.leftMouseUp,x2,y2)
