import 'package:somnio/src/utils/scroll_window.dart';
import 'package:test/test.dart';

void main() {
  group('visibleRows', () {
    test('renders the whole list when it fits in the window', () {
      expect(visibleRows(total: 10, terminalLines: 40), 10);
    });

    test('renders the whole list when the height is unknown (not a tty)', () {
      expect(visibleRows(total: 23, terminalLines: null), 23);
      expect(visibleRows(total: 23, terminalLines: 0), 23);
    });

    test('leaves room for the prompt, the status line and one spare row', () {
      // The 23-skill menu in the 20-row window that duplicated its first
      // four entries: at most 17 option rows may be painted.
      expect(visibleRows(total: 23, terminalLines: 20), 20 - kReservedRows);
    });

    test('never claims more rows than the window has', () {
      for (var lines = 4; lines <= 60; lines++) {
        final visible = visibleRows(total: 23, terminalLines: lines);
        expect(
          visible + kReservedRows <= lines || visible == kMinimumVisibleRows,
          isTrue,
          reason: 'frame overflows a $lines-row window',
        );
      }
    });

    test('falls back to a minimum in a very short window', () {
      expect(visibleRows(total: 23, terminalLines: 4), kMinimumVisibleRows);
      expect(visibleRows(total: 23, terminalLines: 1), kMinimumVisibleRows);
    });

    test('never exceeds the option count in a very short window', () {
      expect(visibleRows(total: 2, terminalLines: 1), 2);
    });

    test('an empty list needs no rows', () {
      expect(visibleRows(total: 0, terminalLines: 20), 0);
    });
  });

  group('scrollOffset', () {
    test('stays at the top while the list fits', () {
      expect(
        scrollOffset(index: 7, previousOffset: 0, visible: 10, total: 10),
        0,
      );
    });

    test('does not move while the cursor is inside the window', () {
      expect(
        scrollOffset(index: 6, previousOffset: 4, visible: 5, total: 23),
        4,
      );
    });

    test('scrolls down by the minimum when the cursor passes the bottom', () {
      expect(
        scrollOffset(index: 9, previousOffset: 4, visible: 5, total: 23),
        5,
      );
    });

    test('scrolls up to the cursor when it passes the top', () {
      expect(
        scrollOffset(index: 2, previousOffset: 6, visible: 5, total: 23),
        2,
      );
    });

    test('clamps to the last full window when wrapping to the end', () {
      expect(
        scrollOffset(index: 22, previousOffset: 0, visible: 5, total: 23),
        18,
      );
    });

    test('clamps a stale offset left over from a taller window', () {
      expect(
        scrollOffset(index: 0, previousOffset: 21, visible: 5, total: 23),
        0,
      );
    });

    test('keeps the cursor visible for every index at every offset', () {
      const total = 23;
      const visible = 5;
      var offset = 0;
      for (var index = 0; index < total; index++) {
        offset = scrollOffset(
          index: index,
          previousOffset: offset,
          visible: visible,
          total: total,
        );
        expect(index, greaterThanOrEqualTo(offset));
        expect(index, lessThan(offset + visible));
        expect(offset + visible, lessThanOrEqualTo(total));
      }
    });
  });
}
