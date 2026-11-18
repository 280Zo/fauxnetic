import 'people_repo.dart';
import 'person.dart';

/// Deletes every person whose voice has expired (through [delete], which removes their voices,
/// recordings and lines) and returns their names.
Future<List<String>> expireVoices(
  PeopleRepo people,
  Future<void> Function(String id) delete,
  DateTime now,
  Duration keepFor,
) async {
  final names = <String>[];
  for (final p in await people.all()) {
    if (!isPersonExpired(p, now, keepFor)) continue;
    await delete(p.id);
    names.add(p.name);
  }
  return names;
}

/// How many people were created more than [d] before [now]: the ones a switch to [d] deletes at once.
int voicesOlderThan(List<Person> people, Duration d, DateTime now) =>
    people.where((p) => p.createdAt != null && !now.isBefore(p.createdAt!.add(d))).length;

/// "deleted in 5 h" from an hour up (rounded down), else "deleted in 40 min" (rounded up, at least 1).
String timeLeft(Duration d) {
  if (d >= const Duration(hours: 1)) return 'deleted in ${d.inHours} h';
  final minutes = (d.inSeconds / 60).ceil();
  return 'deleted in ${minutes < 1 ? 1 : minutes} min';
}
