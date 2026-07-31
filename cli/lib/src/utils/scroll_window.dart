/// Viewport math for the scrolling interactive pickers.
///
/// Kept free of any I/O so it can be unit-tested: the rendering component in
/// `scrolling_picker.dart` only turns these numbers into lines.
///
/// The pickers redraw by moving the cursor up over the lines they wrote and
/// erasing them. A terminal cannot move the cursor above the top of its
/// window, so a frame taller than the window can never be fully erased and
/// every redraw leaves another copy of its first lines behind — the duplicated
/// menu entries this math exists to prevent.
library;

/// Lines a frame spends on things other than options: the prompt line, the
/// status/scroll-indicator line, and one spare row so writing the frame never
/// scrolls the window.
const int kReservedRows = 3;

/// The fewest option rows worth rendering, even in a very short window.
const int kMinimumVisibleRows = 3;

/// How many option rows fit in a window [terminalLines] tall.
///
/// Returns [total] when the whole list fits or when the height is unknown
/// ([terminalLines] null or non-positive, e.g. output is not a terminal).
int visibleRows({required int total, required int? terminalLines}) {
  if (total <= 0) return 0;
  if (terminalLines == null || terminalLines <= 0) return total;

  final available = terminalLines - kReservedRows;
  if (available >= total) return total;
  if (available < kMinimumVisibleRows) {
    return total < kMinimumVisibleRows ? total : kMinimumVisibleRows;
  }
  return available;
}

/// The index of the first option to render so that [index] stays visible.
///
/// Scrolls by the minimum amount: the window only moves when the cursor would
/// otherwise fall outside it, which keeps the list steady while navigating.
int scrollOffset({
  required int index,
  required int previousOffset,
  required int visible,
  required int total,
}) {
  if (visible >= total || visible <= 0) return 0;

  final maxOffset = total - visible;
  var offset = previousOffset.clamp(0, maxOffset);
  if (index < offset) offset = index;
  if (index >= offset + visible) offset = index - visible + 1;
  return offset.clamp(0, maxOffset);
}
