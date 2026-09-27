import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // The smallest the app is laid out for: a 360-wide phone column (the
    // compact layout's design width), 600 tall so a page's app bar, a few
    // rows and a bottom bar all fit. The content's size, so the title bar
    // is added on top of it.
    self.contentMinSize = NSSize(width: 360, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
