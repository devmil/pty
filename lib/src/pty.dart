import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:pty/pty.dart';
import 'package:pty/src/pty_core.dart';

abstract class BasePseudoTerminal implements PseudoTerminal {
  BasePseudoTerminal(this._core);

  late final PtyCore _core;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return _core.kill(signal);
  }

  // int get pid {
  //   return _core.pid;
  // }

  @override
  void write(String input) {
    final data = utf8.encode(input);
    _core.write(data);
  }

  @override
  void resize(int width, int height) {
    _core.resize(width, height);
  }
}

/// A polling based PseudoTerminal implementation. Mainly used in flutter debug
/// mode to make hot reload work. The underlying PtyCore must be non-blocking.
class PollingPseudoTerminal extends BasePseudoTerminal {
  PollingPseudoTerminal(PtyCore _core) : super(_core);

  //initialize them late to avoid having any closures in the instance
  //so that this PollingPseudoTerminal can be passed to an Isolate
  late Completer<int> _exitCode;
  late StreamController<String> _out;
  final _rawDataBuffer = List<int>.empty(growable: true);
  bool _initialized = false;

  @override
  void init() {
    _exitCode = Completer<int>();
    _out = StreamController<String>();
    _initialized = true;
    Timer.periodic(Duration(milliseconds: 5), _poll);
  }

  void _poll(Timer timer) {
    final exit = _core.exitCodeNonBlocking();
    if (exit != null) {
      _exitCode.complete(exit);
      _out.close();
      timer.cancel();
      return;
    }

    var receivedSomething = false;

    var data = _core.read();
    while (data != null) {
      receivedSomething = true;
      _rawDataBuffer.addAll(data);
      data = _core.read();
    }
    if (!_initialized) {
      return;
    }
    if (receivedSomething && _rawDataBuffer.isNotEmpty) {
      try {
        final strContent = utf8.decode(_rawDataBuffer);
        _rawDataBuffer.clear();
        _out.add(strContent);
      } on FormatException catch (_) {
        // FormatException is thrown when the data contains incomplete
        // UTF-8 byte sequences.
        // int this case we do nothing and wait for the next chunk of data
        // to arrive
      }
    }
  }

  @override
  Future<int> get exitCode {
    return _exitCode.future;
  }

  @override
  Stream<String> get out {
    return _out.stream;
  }

  @override
  void ackProcessed() {
    // NOOP
  }
}

enum BlockingPseudoTerminalEvent { data, exitCode }
enum BlockingPseudoTerminalCommand { port, ack }

/// An isolate based PseudoTerminal implementation. Performs better than
/// PollingPseudoTerminal and requires less resource. However this prevents
/// flutter hot reload from working. Ideal for release builds. The underlying
/// PtyCore must be blocking.
class BlockingPseudoTerminal extends BasePseudoTerminal {
  BlockingPseudoTerminal(PtyCore _core, this._syncProcessed) : super(_core);

  late SendPort _sendPort;
  late Completer<int> _exitCodeCompleter;
  final bool _syncProcessed;
  late final StreamController<String> _outStreamController;

  @override
  void init() async {
    _outStreamController = StreamController<String>();
    out = _outStreamController.stream;
    _exitCodeCompleter = Completer<int>();

    final receivePort = ReceivePort();
    receivePort.listen((msg) {
      BlockingPseudoTerminalEvent evt = msg[0];
      switch (evt) {
        case BlockingPseudoTerminalEvent.data:
          _outStreamController.sink.add(msg[1]);
          break;
        case BlockingPseudoTerminalEvent.exitCode:
          _exitCodeCompleter.complete(msg[1]);
          break;
      }
    });
    final firstReceivePort = ReceivePort();
    Isolate.spawn(_readUntilExit,
        _IsolateArgs(firstReceivePort.sendPort, _core, _syncProcessed));

    _sendPort = await firstReceivePort.first;
    _sendPort.send([BlockingPseudoTerminalCommand.port, receivePort.sendPort]);
  }

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  late Stream<String> out;

  @override
  void ackProcessed() {
    if (_syncProcessed) {
      _sendPort.send([BlockingPseudoTerminalCommand.ack]);
    }
  }
}

/// Argument to a isolate entry point, with a sendPort and a custom value.
/// Reduces the effort to establish bi-directional communication between isolate
/// and main thread in many cases.
class _IsolateArgs<T> {
  _IsolateArgs(this.sendPort, this.arg, this.syncProcessed);

  final SendPort sendPort;
  final T arg;
  final bool syncProcessed;
}

void _readUntilExit(_IsolateArgs<PtyCore> ctx) async {
  final rp = ReceivePort();
  var port = ctx.sendPort;
  port.send(rp.sendPort);

  final loopController = StreamController<bool>();

  rp.listen((message) {
    BlockingPseudoTerminalCommand cmd = message[0];
    switch (cmd) {
      case BlockingPseudoTerminalCommand.port:
        port = message[1];
        loopController.sink.add(true); //enable the first iteration
        break;
      case BlockingPseudoTerminalCommand.ack:
        if (ctx.syncProcessed) {
          loopController.sink.add(true);
        }
        break;
    }
  });

  // set [sync] to true because PtyCore.read() is blocking and prevents the
  // event loop from working.
  final input = StreamController<List<int>>(sync: true);

  input.stream.transform(utf8.decoder).listen((event) {
    port.send([BlockingPseudoTerminalEvent.data, event]);
  });

  await for (final _ in loopController.stream) {
    final data = ctx.arg.read();

    if (data == null) {
      port.send(
          [BlockingPseudoTerminalEvent.exitCode, ctx.arg.exitCodeBlocking()]);
      await input.close();
      break;
    }

    input.sink.add(data);

    // when we don't sync with the data processing then just schedule the next loop
    // iteration
    // Otherwise the loop will continue when the processing of the data is
    // finished (signaled via [PseudoTerminal.ackProcessed])
    if (!ctx.syncProcessed) {
      loopController.sink.add(true);
    }
  }
  await loopController.close();
}
