import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'temp_sweeper.dart';

abstract class KeyStore {
  Future<List<int>?> read();
  Future<void> write(List<int> key);
}

/// The vault key lives in Android Keystore-backed secure storage, never in app files.
class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage(aOptions: androidOptions);

  /// resetOnError defaults to true in flutter_secure_storage, which would silently erase the key
  /// on any Keystore hiccup and make every stored voice unreadable. Fail loudly instead.
  static const androidOptions = AndroidOptions(resetOnError: false);
  static const keyName = 'vault_key_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<List<int>?> read() async {
    final existing = await _storage.read(key: keyName);
    return existing == null ? null : _fromHex(existing);
  }

  @override
  Future<void> write(List<int> key) => _storage.write(key: keyName, value: _toHex(key));

  static String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static List<int> _fromHex(String s) =>
      List<int>.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16));
}

class VaultError implements Exception {
  const VaultError(this.message);
  final String message;
  @override
  String toString() => 'VaultError: $message';
}

/// The vault's key is gone or no longer matches the data it encrypted.
class VaultKeyLost implements Exception {
  const VaultKeyLost();
  @override
  String toString() =>
      'The phone lost the key that protects saved voices, so they can no longer be opened. Delete the app data to start over.';
}

const _checkPlaintext = 'fauxnetic-vault-check-v1';

/// AES-256-GCM file encryption. File layout: nonce (12) | ciphertext | tag (16).
///
/// [checkFile] holds a small encrypted marker written when the key is created. If the marker
/// exists but the key is missing or different, the vault refuses to work instead of quietly
/// creating a new key that would orphan everything already stored.
class Vault {
  Vault(this._keys, {this.checkFile});

  final KeyStore _keys;
  final File? checkFile;
  final _cipher = AesGcm.with256bits();
  Future<SecretKey>? _key;

  Future<SecretKey> _secret() => _key ??= _loadKey().catchError((Object e) {
    _key = null;
    throw e;
  });

  Future<SecretKey> _loadKey() async {
    final check = checkFile;
    final stored = await _keys.read();
    if (stored == null) {
      if (check != null && await check.exists()) throw const VaultKeyLost();
      final r = Random.secure();
      final fresh = List<int>.generate(32, (_) => r.nextInt(256));
      await _keys.write(fresh);
      final key = SecretKey(fresh);
      if (check != null) await _write(utf8.encode(_checkPlaintext), check, key);
      return key;
    }
    final key = SecretKey(stored);
    if (check != null) {
      if (await check.exists()) {
        try {
          if (utf8.decode(await _read(check, key)) != _checkPlaintext) throw const VaultKeyLost();
        } on VaultError {
          throw const VaultKeyLost();
        }
      } else {
        await _write(utf8.encode(_checkPlaintext), check, key);
      }
    }
    return key;
  }

  Future<void> encryptBytes(List<int> plain, File out) async => _write(plain, out, await _secret());

  Future<List<int>> decryptFile(File f) async => _read(f, await _secret());

  Future<void> _write(List<int> plain, File out, SecretKey key) async {
    final box = await _cipher.encrypt(plain, secretKey: key);
    await out.parent.create(recursive: true);
    final tmp = File('${out.path}.tmp');
    await tmp.writeAsBytes([...box.nonce, ...box.cipherText, ...box.mac.bytes], flush: true);
    await tmp.rename(out.path);
  }

  Future<List<int>> _read(File f, SecretKey key) async {
    final bytes = await f.readAsBytes();
    if (bytes.length < 28) throw const VaultError('file too short');
    final box = SecretBox(
      bytes.sublist(12, bytes.length - 16),
      nonce: bytes.sublist(0, 12),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    try {
      return await _cipher.decrypt(box, secretKey: key);
    } on SecretBoxAuthenticationError {
      throw const VaultError('authentication failed');
    }
  }

  Future<File> decryptToTemp(File f, TempSweeper temp, String suffix) async {
    final plain = await decryptFile(f);
    final out = await temp.create(suffix);
    await out.writeAsBytes(plain, flush: true);
    return out;
  }
}
