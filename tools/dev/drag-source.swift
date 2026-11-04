import AppKit
final class SourceView: NSView, NSDraggingSource {
 let file: URL
 let result: URL
 init(file: URL, result: URL) { self.file=file; self.result=result; super.init(frame: NSRect(x:0,y:0,width:200,height:150)) }
 required init?(coder: NSCoder) { fatalError() }
 override func draw(_ rect: NSRect) { NSColor.systemBlue.setFill(); bounds.fill(); ("Placeholder PKG" as NSString).draw(at:NSPoint(x:20,y:65),withAttributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:18)]) }
 override func mouseDown(with event: NSEvent) {
  let item=NSDraggingItem(pasteboardWriter:file as NSURL)
  item.setDraggingFrame(NSRect(x:30,y:40,width:100,height:70), contents:NSImage(systemSymbolName:"shippingbox",accessibilityDescription:nil))
  beginDraggingSession(with:[item],event:event,source:self)
 }
 func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
 func draggingSession(_ session:NSDraggingSession,endedAt point:NSPoint,operation:NSDragOperation) {
  try? "operation=\(operation.rawValue)".write(to:result,atomically:true,encoding:.utf8)
  NSApp.terminate(nil)
 }
}
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let height=NSScreen.main!.frame.height
let window=NSWindow(contentRect:NSRect(x:40,y:height-400,width:200,height:150),styleMask:[.titled],backing:.buffered,defer:false)
window.title="PKD Placeholder Drag"
window.contentView=SourceView(file:URL(fileURLWithPath:CommandLine.arguments[1]),result:URL(fileURLWithPath:CommandLine.arguments[2]))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps:true)
app.run()
