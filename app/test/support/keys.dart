import 'package:fauxnetic/storage/vault.dart';

/// In-memory key store for tests. Starts empty unless a key is given.
class MemoryKeyStore implements KeyStore {
  MemoryKeyStore([this.key]);
  List<int>? key;
  var writes = 0;

  @override
  Future<List<int>?> read() async => key;

  @override
  Future<void> write(List<int> k) async {
    writes++;
    key = k;
  }
}

/// A store that already holds a fixed key.
class FixedKeyStore extends MemoryKeyStore {
  FixedKeyStore([int seed = 0]) : super(List<int>.generate(32, (i) => (i * 7 + seed) % 256));
}
