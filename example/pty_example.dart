import 'dart:convert';

import 'package:pty/pty.dart';

void main() async {
  final pty = PseudoTerminal.start('bash', []);
  final utf8Encoder = Utf8Encoder();
  final utf8Decoder = Utf8Decoder();

  pty.write(utf8Encoder.convert('ls\n'));

  pty.out.listen((data) {
    print(utf8Decoder.convert(data));
  });

  print(await pty.exitCode);
}
