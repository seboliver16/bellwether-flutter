// Where the SDK keeps what must outlive a launch: the queue, who and when, the last good settings file and the
// "session open" marker, each a small text file by name. Core asks a Store; FileStore is the real one, a folder in the
// app's support directory, and tests hand Core one in memory.

import 'dart:io';

abstract interface class Store {
  // The text kept under `name`, or null when there is none.
  Future<String?> read(String name);
  Future<void> write(String name, String text);
  Future<void> remove(String name);
}

final class FileStore implements Store {
  // The folder may not be known yet when the SDK starts (path_provider answers asynchronously), so it's a future.
  FileStore(this._folder);

  final Future<Directory> _folder;

  Future<File> _file(String name) async => File('${(await _folder).path}/$name');

  @override
  Future<String?> read(String name) async {
    final file = await _file(name);
    return await file.exists() ? file.readAsString() : null;
  }

  // Written to a temporary file, then renamed over the old one, so a launch never reads half a file.
  @override
  Future<void> write(String name, String text) async {
    final file = await _file(name);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }

  @override
  Future<void> remove(String name) async {
    final file = await _file(name);
    if (await file.exists()) await file.delete();
  }
}
