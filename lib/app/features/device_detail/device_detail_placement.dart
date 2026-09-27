/// Where the app shell has put a device's own page — all the page needs to
/// word its way out once the device is no longer paired.
///
/// Told by the shell, which decides it from the window once; the page never
/// reads the window. What leaving does is still the shell's, through
/// `DeviceDetailPage.onGone`: this only picks the words for it.
enum DeviceDetailPlacement {
  /// A page of its own over the device list: a phone's pushed page, or the
  /// pane beside a narrow rail. Leaving goes back to the list.
  overList,

  /// The pane beside the device list, on a window wide enough for both. The
  /// list is already on screen, so leaving only closes this pane.
  besideList,
}
