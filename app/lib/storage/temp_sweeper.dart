import 'dart:io';
import 'dart:math';

/// Short-lived decrypted files live only in `<cacheDir>/vault-tmp/` and are deleted after use,
/// with a sweep on every launch for anything a crash left behind.
class TempSweeper {
  TempSweeper(Directory cacheDir) : dir = Directory('${cacheDir.path}/vault-tmp');

  final Directory dir;
  final _random = Random.secure();

  Future<File> create(String suffix) async {
    await dir.create(recursive: true);
    final name = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return File('${dir.path}/$name$suffix');
  }

  Future<void> release(File f) async {
    if (f.parent.absolute.path != dir.absolute.path) {
      throw ArgumentError.value(f.path, 'f', 'not a temp file of this sweeper');
    }
    if (await f.exists()) await f.delete();
  }

  Future<int> sweep() async {
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final e in dir.list()) {
      await e.delete(recursive: true);
      n++;
    }
    return n;
  }
}
