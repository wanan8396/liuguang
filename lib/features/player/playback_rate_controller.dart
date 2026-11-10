/// Serializes speed commands so a quick release cannot leave the player at 2x.
class PlaybackRateController {
  PlaybackRateController(this._write);

  final Future<void> Function(double) _write;
  Future<void> _pending = Future<void>.value();
  double selected = 1;
  bool holding = false, _closed = false;
  int _revision = 0;

  double get effective => holding ? 2 : selected;

  Future<void> _apply(double rate) {
    final operation = _pending.then((_) async {
      if (!_closed) await _write(rate);
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> select(double rate) async {
    if (_closed) return;
    final previous = selected;
    final revision = ++_revision;
    selected = rate;
    holding = false;
    try {
      await _apply(rate);
    } catch (_) {
      if (_revision == revision) selected = previous;
      rethrow;
    }
  }

  Future<void> beginHold() async {
    if (_closed || holding) return;
    final revision = ++_revision;
    holding = true;
    try {
      await _apply(2);
    } catch (_) {
      if (_revision == revision) holding = false;
      rethrow;
    }
  }

  Future<void> endHold() {
    if (_closed || !holding) return Future<void>.value();
    _revision++;
    holding = false;
    return _apply(selected);
  }

  Future<void> reapply() => _apply(effective);

  Future<void> close() {
    _closed = true;
    holding = false;
    return _pending;
  }
}
