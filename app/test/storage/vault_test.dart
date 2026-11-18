import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauxnetic/storage/temp_sweeper.dart';
import 'package:fauxnetic/storage/vault.dart';

import '../support/keys.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('vault'));
  tearDown(() => dir.deleteSync(recursive: true));

  final marker = List<int>.generate(32, (i) => 0x41 + (i % 26));
  final plain = [...List<int>.generate(1000, (i) => Random(1).nextInt(256)), ...marker];

  test('round trip', () async {
    final v = Vault(FixedKeyStore(1));
    final f = File('${dir.path}/a.bin');
    await v.encryptBytes(plain, f);
    expect(await v.decryptFile(f), plain);
  });

  test('ciphertext does not contain the plaintext', () async {
    final v = Vault(FixedKeyStore(1));
    final f = File('${dir.path}/a.bin');
    await v.encryptBytes(plain, f);
    final bytes = await f.readAsBytes();
    final hay = String.fromCharCodes(bytes);
    expect(hay.contains(String.fromCharCodes(marker)), isFalse);
    expect(bytes.length, plain.length + 12 + 16);
  });

  test('tampered file throws VaultError', () async {
    final v = Vault(FixedKeyStore(1));
    final f = File('${dir.path}/a.bin');
    await v.encryptBytes(plain, f);
    final bytes = await f.readAsBytes();
    bytes[40] ^= 0xFF;
    await f.writeAsBytes(bytes);
    await expectLater(v.decryptFile(f), throwsA(isA<VaultError>()));
  });

  test('wrong key throws VaultError', () async {
    final f = File('${dir.path}/a.bin');
    await Vault(FixedKeyStore(1)).encryptBytes(plain, f);
    await expectLater(Vault(FixedKeyStore(2)).decryptFile(f), throwsA(isA<VaultError>()));
  });

  test('truncated file throws VaultError', () async {
    final f = File('${dir.path}/a.bin');
    await f.writeAsBytes([1, 2, 3]);
    await expectLater(Vault(FixedKeyStore(1)).decryptFile(f), throwsA(isA<VaultError>()));
  });

  test('first use creates and stores exactly one key, even when concurrent', () async {
    final ks = MemoryKeyStore();
    final v = Vault(ks, checkFile: File('${dir.path}/vault.check'));
    final a = File('${dir.path}/a.bin'), b = File('${dir.path}/b.bin');
    await Future.wait([v.encryptBytes(plain, a), v.encryptBytes(plain, b)]);
    expect(ks.writes, 1);
    expect(await v.decryptFile(a), plain);
    expect(await v.decryptFile(b), plain);
  });

  test('missing key with existing vault data throws VaultKeyLost and writes no new key', () async {
    final check = File('${dir.path}/vault.check');
    await Vault(MemoryKeyStore(), checkFile: check).encryptBytes(plain, File('${dir.path}/a.bin'));
    final emptied = MemoryKeyStore();
    await expectLater(
      Vault(emptied, checkFile: check).encryptBytes(plain, File('${dir.path}/b.bin')),
      throwsA(isA<VaultKeyLost>()),
    );
    expect(emptied.writes, 0);
  });

  test('a different key than the vault was made with throws VaultKeyLost', () async {
    final check = File('${dir.path}/vault.check');
    await Vault(FixedKeyStore(1), checkFile: check).encryptBytes(plain, File('${dir.path}/a.bin'));
    await expectLater(
      Vault(FixedKeyStore(2), checkFile: check).decryptFile(File('${dir.path}/a.bin')),
      throwsA(isA<VaultKeyLost>()),
    );
  });

  test('secure key store never resets on error', () {
    expect(SecureKeyStore.androidOptions.toMap()['resetOnError'], 'false');
  });

  test('decryptToTemp writes plaintext into the sweeper directory', () async {
    final v = Vault(FixedKeyStore(1));
    final t = TempSweeper(dir);
    final f = File('${dir.path}/a.bin');
    await v.encryptBytes(plain, f);
    final tmp = await v.decryptToTemp(f, t, '.wav');
    expect(tmp.path, startsWith('${dir.path}/vault-tmp/'));
    expect(tmp.path, endsWith('.wav'));
    expect(await tmp.readAsBytes(), plain);
    await t.release(tmp);
    expect(tmp.existsSync(), isFalse);
  });
}
