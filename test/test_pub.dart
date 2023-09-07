// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Test infrastructure for testing pub.
///
/// Unlike typical unit tests, most pub tests are integration tests that stage
/// some stuff on the file system, run pub, and then validate the results. This
/// library provides an API to build tests like that.
library;

import 'dart:convert';
import 'dart:core';
import 'dart:io' hide BytesBuilder;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pub/src/entrypoint.dart';
import 'package:pub/src/exit_codes.dart' as exit_codes;
import 'package:pub/src/git.dart' as git;
import 'package:pub/src/http.dart';
import 'package:pub/src/io.dart';
import 'package:pub/src/lock_file.dart';
import 'package:pub/src/log.dart' as log;
import 'package:pub/src/package_name.dart';
import 'package:pub/src/source/hosted.dart';
import 'package:pub/src/system_cache.dart';
import 'package:pub/src/utils.dart';
import 'package:pub/src/validator.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart' hide fail;
import 'package:test/test.dart' as test show fail;
import 'package:test_process/test_process.dart';

import 'descriptor.dart' as d;
import 'package_server.dart';

export 'package_server.dart' show PackageServer;

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// enabled.
Matcher isMinifiedDart2JSOutput =
    isNot(contains('// The code supports the following hooks'));

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// disabled.
Matcher isUnminifiedDart2JSOutput =
    contains('// The code supports the following hooks');

/// Converts [value] into a YAML string.
String yaml(Object? value) => jsonEncode(value);

/// The path of the package cache directory used for tests, relative to the
/// sandbox directory.
const String cachePath = 'cache';

/// The path of the config directory used for tests, relative to the
/// sandbox directory.
const String configPath = '.config';

d.DirectoryDescriptor configDir(Iterable<d.Descriptor> contents) =>
    d.dir(configPath, [d.dir('dart', contents)]);

/// The path of the mock app directory used for tests, relative to the sandbox
/// directory.
const String appPath = 'myapp';

/// The path of the ".dart_tool/package_config.json" file in the mock app used
/// for tests, relative to the sandbox directory.
String packageConfigFilePath =
    p.join(appPath, '.dart_tool', 'package_config.json');

/// The entry from the `.dart_tool/package_config.json` file for [packageName].
Map<String, dynamic> packageSpec(String packageName) => json
    .decode(File(d.path(packageConfigFilePath)).readAsStringSync())['packages']
    .firstWhere(
      (e) => e['name'] == packageName,
      orElse: () => null,
    ) as Map<String, dynamic>;

/// The suffix appended to a built snapshot.
const versionSuffix = testVersion;

/// Enum identifying a pub command that can be run with a well-defined success
/// output.
class RunCommand {
  static final add = RunCommand(
    'add',
    RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'),
  );
  static final get = RunCommand(
    'get',
    RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'),
  );
  static final upgrade = RunCommand(
    'upgrade',
    RegExp(r'''
(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)($|
\d+ packages? (has|have) newer versions incompatible with dependency constraints.
Try `dart pub outdated` for more information.$)'''),
  );
  static final downgrade = RunCommand(
    'downgrade',
    RegExp(r'''(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)($|
\d+ packages? (has|have) newer versions incompatible with dependency constraints.
Try `dart pub outdated` for more information.$)'''),
  );
  static final remove = RunCommand(
    'remove',
    RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'),
  );

  final String name;
  final RegExp success;
  RunCommand(this.name, this.success);
}

/// Runs the tests defined within [callback] using both pub get and pub upgrade.
///
/// Many tests validate behavior that is the same between pub get and
/// upgrade have the same behavior. Instead of duplicating those tests, this
/// takes a callback that defines get/upgrade agnostic tests and runs them
/// with both commands.
void forBothPubGetAndUpgrade(void Function(RunCommand) callback) {
  group(RunCommand.get.name, () => callback(RunCommand.get));
  group(RunCommand.upgrade.name, () => callback(RunCommand.upgrade));
}

/// Invokes the pub [command] and validates that it completes in an expected
/// way.
///
/// By default, this validates that the command completes successfully and
/// understands the normal output of a successful pub command. If [warning] is
/// given, it expects the command to complete successfully *and* print [warning]
/// to stderr. If [error] is given, it expects the command to *only* print
/// [error] to stderr. [output], [error], [silent], and [warning] may be
/// strings, [RegExp]s, or [Matcher]s.
///
/// If [exitCode] is given, expects the command to exit with that code.
// TODO(rnystrom): Clean up other tests to call this when possible.
Future<void> pubCommand(
  RunCommand command, {
  Iterable<String>? args,
  Object? output,
  Object? error,
  Object? silent,
  Object? warning,
  int? exitCode,
  Map<String, String?>? environment,
  String? workingDirectory,
  bool includeParentHomeAndPath = true,
}) async {
  if (error != null && warning != null) {
    throw ArgumentError("Cannot pass both 'error' and 'warning'.");
  }

  var allArgs = [command.name];
  if (args != null) allArgs.addAll(args);

  output ??= command.success;

  if (error != null && exitCode == null) exitCode = 1;

  // No success output on an error.
  if (error != null) output = null;
  if (warning != null) error = warning;

  await runPub(
    args: allArgs,
    output: output,
    error: error,
    silent: silent,
    exitCode: exitCode,
    environment: environment,
    workingDirectory: workingDirectory,
    includeParentHomeAndPath: includeParentHomeAndPath,
  );
}

Future<void> pubAdd({
  Iterable<String>? args,
  Object? output,
  Object? error,
  Object? warning,
  int? exitCode,
  Map<String, String>? environment,
  String? workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.add,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubGet({
  Iterable<String>? args,
  Object? output,
  Object? error,
  Object? silent,
  Object? warning,
  int? exitCode,
  Map<String, String?>? environment,
  String? workingDirectory,
  bool includeParentHomeAndPath = true,
}) async =>
    await pubCommand(
      RunCommand.get,
      args: args,
      output: output,
      error: error,
      silent: silent,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
      includeParentHomeAndPath: includeParentHomeAndPath,
    );

Future<void> pubUpgrade({
  Iterable<String>? args,
  Object? output,
  Object? error,
  Object? warning,
  Object? silent,
  int? exitCode,
  Map<String, String>? environment,
  String? workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.upgrade,
      args: args,
      output: output,
      error: error,
      warning: warning,
      silent: silent,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubDowngrade({
  Iterable<String>? args,
  Object? output,
  Object? error,
  Object? warning,
  int? exitCode,
  Map<String, String>? environment,
  String? workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.downgrade,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubRemove({
  Iterable<String>? args,
  Object? output,
  Object? error,
  Object? warning,
  int? exitCode,
  Map<String, String>? environment,
  String? workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.remove,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

/// Schedules starting the "pub [global] run" process and validates the
/// expected startup output.
///
/// If [global] is `true`, this invokes "pub global run", otherwise it does
/// "pub run".
///
/// Returns the `pub run` process.
Future<PubProcess> pubRun({
  bool global = false,
  required Iterable<String> args,
  Map<String, String>? environment,
  bool verbose = true,
}) async {
  var pubArgs = global ? ['global', 'run'] : ['run'];
  pubArgs.addAll(args);
  var pub = await startPub(
    args: pubArgs,
    environment: environment,
    verbose: verbose,
  );

  // Loading sources and transformers isn't normally printed, but the pub test
  // infrastructure runs pub in verbose mode, which enables this.
  expect(pub.stdout, mayEmitMultiple(startsWith('Loading')));

  return pub;
}

/// Schedules renaming (moving) the directory at [from] to [to], both of which
/// are assumed to be relative to [d.sandbox].
void renameInSandbox(String from, String to) {
  renameDir(_pathInSandbox(from), _pathInSandbox(to));
}

/// Schedules creating a symlink at path [symlink] that points to [target],
/// both of which are assumed to be relative to [d.sandbox].
void symlinkInSandbox(String target, String symlink) {
  createSymlink(_pathInSandbox(target), _pathInSandbox(symlink));
}

/// Runs Pub with [args] and validates that its results match [output] (or
/// [outputJson]), [error], [silent] (for logs that are silent by default), and
/// [exitCode].
///
/// [output], [error], and [silent] can be [String]s, [RegExp]s, or [Matcher]s.
///
/// If [input] is given, writes given lines into process stdin stream.
///
/// If [outputJson] is given, validates that pub outputs stringified JSON
/// matching that object, which can be a literal JSON object or any other
/// [Matcher].
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
Future<void> runPub({
  List<String>? args,
  Object? output,
  Object? error,
  Object? outputJson,
  Object? silent,
  int? exitCode,
  String? workingDirectory,
  Map<String, String?>? environment,
  List<String>? input,
  bool includeParentHomeAndPath = true,
}) async {
  exitCode ??= exit_codes.SUCCESS;
  // Cannot pass both output and outputJson.
  assert(output == null || outputJson == null);

  var pub = await startPub(
    args: args,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentHomeAndPath: includeParentHomeAndPath,
  );

  if (input != null) {
    input.forEach(pub.stdin.writeln);
    await pub.stdin.flush();
  }

  await pub.shouldExit(exitCode);

  var actualOutput = (await pub.stdoutStream().toList()).join('\n');
  var actualError = (await pub.stderrStream().toList()).join('\n');
  var actualSilent = (await pub.silentStream().toList()).join('\n');

  var failures = <String>[];
  if (outputJson == null) {
    _validateOutput(failures, 'stdout', output, actualOutput);
  } else {
    _validateOutputJson(failures, 'stdout', outputJson, actualOutput);
  }

  _validateOutput(failures, 'stderr', error, actualError);
  _validateOutput(failures, 'silent', silent, actualSilent);

  if (failures.isNotEmpty) {
    test.fail(failures.join('\n'));
  }
}

/// Like [startPub], but runs `pub lish` in particular with [server] used both
/// as the OAuth2 server (with "/token" as the token endpoint) and as the
/// package server.
///
/// Any futures in [args] will be resolved before the process is started.
Future<PubProcess> startPublish(
  PackageServer server, {
  List<String>? args,
  bool overrideDefaultHostedServer = true,
  Map<String, String>? environment,
  String path = '',
}) async {
  var tokenEndpoint = Uri.parse(server.url).resolve('/token').toString();
  args = ['lish', ...?args];
  return await startPub(
    args: args,
    tokenEndpoint: tokenEndpoint,
    environment: {
      if (overrideDefaultHostedServer)
        '_PUB_TEST_DEFAULT_HOSTED_URL': server.url + path
      else
        'PUB_HOSTED_URL': server.url + path,
      if (environment != null) ...environment,
    },
  );
}

/// Handles the beginning confirmation process for uploading a packages.
///
/// Ensures that the right output is shown and then enters "y" to confirm the
/// upload.
Future<void> confirmPublish(TestProcess pub) async {
  // TODO(rnystrom): This is overly specific and inflexible regarding different
  // test packages. Should validate this a little more loosely.
  await expectLater(
    pub.stdout,
    emitsThrough(startsWith('Publishing test_pkg 1.0.0 to ')),
  );
  await expectLater(
    pub.stdout,
    emitsThrough(
      matches(
        r'^Do you want to publish [^ ]+ [^ ]+ (y/N)?',
      ),
    ),
  );
  pub.stdin.writeln('y');
}

/// Resolves [path] relative to the package cache in the sandbox.
String pathInCache(String path) => p.join(d.sandbox, cachePath, path);

/// Gets the absolute path to [relPath], which is a relative path in the test
/// sandbox.
String _pathInSandbox(String relPath) => p.join(d.sandbox, relPath);

const String testVersion = '3.1.2+3';

/// This constraint is compatible with [testVersion].
const String defaultSdkConstraint = '^3.0.2';

/// Gets the environment variables used to run pub in a test context.
Map<String, String> getPubTestEnvironment([String? tokenEndpoint]) => {
      'CI': 'false', // unless explicitly given tests don't run pub in CI mode
      '_PUB_TESTING': 'true',
      '_PUB_TEST_CONFIG_DIR': _pathInSandbox(configPath),
      'PUB_CACHE': _pathInSandbox(cachePath),
      'PUB_ENVIRONMENT': 'test-environment',

      // Ensure a known SDK version is set for the tests that rely on that.
      '_PUB_TEST_SDK_VERSION': testVersion,
      if (tokenEndpoint != null) '_PUB_TEST_TOKEN_ENDPOINT': tokenEndpoint,
      if (_globalServer?.port != null)
        'PUB_HOSTED_URL': 'http://localhost:${_globalServer?.port}',
    };

/// The path to the root of pub's sources in the pub repo.
final String _pubRoot = (() {
  if (!fileExists(p.join('bin', 'pub.dart'))) {
    throw StateError(
      "Current working directory (${p.current} is not pub's root. Run tests from pub's root.",
    );
  }
  return p.current;
})();

/// Starts a Pub process and returns a [PubProcess] that supports interaction
/// with that process.
///
/// Any futures in [args] will be resolved before the process is started.
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
Future<PubProcess> startPub({
  Iterable<String>? args,
  String? tokenEndpoint,
  String? workingDirectory,
  Map<String, String?>? environment,
  bool verbose = true,
  bool includeParentHomeAndPath = true,
}) async {
  args ??= [];

  ensureDir(_pathInSandbox(appPath));

  // If there's a snapshot for "pub" available we use it. If the snapshot is
  // out-of-date local source the tests will be useless, therefore it is
  // recommended to use a temporary file with a unique name for each test run.
  // Note: running tests without a snapshot is significantly slower, use
  // tool/test.dart to generate the snapshot.
  var pubPath = Platform.environment['_PUB_TEST_SNAPSHOT'] ?? '';
  if (pubPath.isEmpty || !fileExists(pubPath)) {
    pubPath = p.absolute(p.join(_pubRoot, 'bin/pub.dart'));
  }

  final dotPackagesPath = (await Isolate.packageConfig).toString();

  var dartArgs = ['--packages=$dotPackagesPath', '--enable-asserts'];
  dartArgs
    ..addAll([pubPath, if (!verbose) '--verbosity=normal'])
    ..addAll(args);

  final systemRoot = Platform.environment['SYSTEMROOT'];
  final tmp = Platform.environment['TMP'];

  final mergedEnvironment = {
    if (includeParentHomeAndPath) ...{
      'HOME': Platform.environment['HOME'] ?? '',
      'PATH': Platform.environment['PATH'] ?? '',
    },
    // These seem to be needed for networking to work.
    if (Platform.isWindows) ...{
      if (systemRoot != null) 'SYSTEMROOT': systemRoot,
      if (tmp != null) 'TMP': tmp,
    },
    ...getPubTestEnvironment(tokenEndpoint),
  };
  for (final e in (environment ?? {}).entries) {
    var value = e.value;
    if (value == null) {
      mergedEnvironment.remove(e.key);
    } else {
      mergedEnvironment[e.key] = value;
    }
  }

  return await PubProcess.start(
    Platform.resolvedExecutable,
    dartArgs,
    environment: mergedEnvironment,
    workingDirectory: workingDirectory ?? _pathInSandbox(appPath),
    description: args.isEmpty ? 'pub' : 'pub ${args.join(' ')}',
    includeParentEnvironment: false,
  );
}

/// A subclass of [TestProcess] that parses pub's verbose logging output and
/// makes [stdout] and [stderr] work as though pub weren't running in verbose
/// mode.
class PubProcess extends TestProcess {
  late final StreamSplitter<(log.Level level, String message)> _logSplitter =
      createLogSplitter();

  StreamSplitter<(log.Level, String)> createLogSplitter() {
    return StreamSplitter(
      StreamGroup.merge([
        _outputToLog(super.stdoutStream(), log.Level.message),
        _outputToLog(super.stderrStream(), log.Level.error),
      ]),
    );
  }

  static Future<PubProcess> start(
    String executable,
    Iterable<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    String? description,
    Encoding encoding = utf8,
    bool forwardStdio = false,
  }) async {
    var process = await Process.start(
      executable,
      arguments.toList(),
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
    );

    if (description == null) {
      var humanExecutable = p.isWithin(p.current, executable)
          ? p.relative(executable)
          : executable;
      description = '$humanExecutable ${arguments.join(' ')}';
    }

    return PubProcess(
      process,
      description,
      encoding: encoding,
      forwardStdio: forwardStdio,
    );
  }

  /// This is protected.
  PubProcess(
    super.process,
    super.description, {
    super.encoding,
    super.forwardStdio,
  });

  final _logLineRegExp = RegExp(r'^([A-Z ]{4})[:|] (.*)$');
  final Map<String, log.Level> _logLevels = [
    log.Level.error,
    log.Level.warning,
    log.Level.message,
    log.Level.io,
    log.Level.solver,
    log.Level.fine,
  ].fold({}, (levels, level) {
    levels[level.name] = level;
    return levels;
  });

  Stream<(log.Level, String message)> _outputToLog(
    Stream<String> stream,
    log.Level defaultLevel,
  ) {
    late log.Level lastLevel;
    return stream.map((line) {
      var match = _logLineRegExp.firstMatch(line);
      if (match == null) return (defaultLevel, line);

      var level = _logLevels[match[1]] ?? lastLevel;
      lastLevel = level;
      return (level, match[2]!);
    });
  }

  @override
  Stream<String> stdoutStream() {
    return _logSplitter.split().expand((entry) {
      final (level, message) = entry;
      if (level != log.Level.message) return [];
      return [message];
    });
  }

  @override
  Stream<String> stderrStream() {
    return _logSplitter.split().expand((entry) {
      final (level, message) = entry;
      if (level != log.Level.error && level != log.Level.warning) {
        return [];
      }
      return [message];
    });
  }

  /// A stream of log messages that are silent by default.
  Stream<String> silentStream() {
    return _logSplitter.split().expand((entry) {
      final (level, message) = entry;
      if (level == log.Level.message) return [];
      if (level == log.Level.error) return [];
      if (level == log.Level.warning) return [];
      return [message];
    });
  }
}

/// Fails the current test if Git is not installed.
///
/// We require machines running these tests to have git installed. This
/// validation gives an easier-to-understand error when that requirement isn't
/// met than just failing in the middle of a test when pub invokes git.
void ensureGit() {
  if (!git.isInstalled) fail('Git must be installed to run this test.');
}

/// Creates a lock file for [package] without running `pub get`.
///
/// [dependenciesInSandBox] is a list of path dependencies to be found in the sandbox
/// directory.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
Future<void> createLockFile(
  String package, {
  Iterable<String>? dependenciesInSandBox,
  Map<String, String>? hosted,
}) async {
  var cache = SystemCache(rootDir: _pathInSandbox(cachePath));

  var lockFile =
      _createLockFile(cache, sandbox: dependenciesInSandBox, hosted: hosted);

  await d.dir(package, [
    d.file(
      'pubspec.lock',
      lockFile.serialize(p.join(d.sandbox, package), cache),
    ),
  ]).create();
}

/// Creates a lock file for [sources] without running `pub get`.
///
/// [sandbox] is a list of path dependencies to be found in the sandbox
/// directory.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
LockFile _createLockFile(
  SystemCache cache, {
  Iterable<String>? sandbox,
  Map<String, String>? hosted,
}) {
  var dependencies = <String, dynamic>{};

  if (sandbox != null) {
    for (var package in sandbox) {
      dependencies[package] = '../$package';
    }
  }

  final packages = <PackageId>[
    ...dependencies.entries.map(
      (entry) => cache.path.parseId(
        entry.key,
        Version(0, 0, 0),
        {'path': entry.value, 'relative': true},
        containingDir: p.join(d.sandbox, appPath),
      ),
    ),
    if (hosted != null)
      ...hosted.entries.map(
        (entry) => PackageId(
          entry.key,
          Version.parse(entry.value),
          ResolvedHostedDescription(
            HostedDescription(
              entry.key,
              'https://pub.dev',
            ),
            sha256: null,
          ),
        ),
      ),
  ];

  return LockFile(packages);
}

/// Uses [client] as the mock HTTP client for this test.
///
/// Note that this will only affect HTTP requests made via http.dart in the
/// parent process.
void useMockClient(MockClient client) {
  var oldInnerClient = innerHttpClient;
  innerHttpClient = client;
  addTearDown(() {
    innerHttpClient = oldInnerClient;
  });
}

/// Describes a map representing a library package with the given [name],
/// [version], and [dependencies].
Map<String, Object> packageMap(
  String name,
  String version, [
  Map? dependencies,
  Map? devDependencies,
  Map? environment,
]) {
  var package = <String, Object>{
    'name': name,
    'version': version,
    'homepage': 'https://pub.dev',
    'description': 'A package, I guess.',
  };

  if (dependencies != null) package['dependencies'] = dependencies;
  if (devDependencies != null) package['dev_dependencies'] = devDependencies;
  if (environment != null) package['environment'] = environment;
  return package;
}

/// Returns the name of the shell script for a binstub named [name].
///
/// Adds a ".bat" extension on Windows.
String binStubName(String name) => Platform.isWindows ? '$name.bat' : name;

/// Compares the [actual] output from running pub with [expected].
///
/// If [expected] is a [String], ignores leading and trailing whitespace
/// differences and tries to report the offending difference in a nice way.
///
/// If it's a [RegExp] or [Matcher], just reports whether the output matches.
void _validateOutput(
  List<String> failures,
  String pipe,
  expected,
  String actual,
) {
  if (expected == null) return;

  if (expected is String) {
    _validateOutputString(failures, pipe, expected, actual);
  } else {
    if (expected is RegExp) expected = matches(expected);
    expect(actual, expected);
  }
}

void _validateOutputString(
  List<String> failures,
  String pipe,
  String expected,
  String actual,
) {
  var actualLines = actual.split('\n');
  var expectedLines = expected.split('\n');

  // Strip off the last line. This lets us have expected multiline strings
  // where the closing ''' is on its own line. It also fixes '' expected output
  // to expect zero lines of output, not a single empty line.
  if (expectedLines.last.trim() == '') {
    expectedLines.removeLast();
  }

  var results = <String>[];
  var failed = false;

  // Compare them line by line to see which ones match.
  var length = max(expectedLines.length, actualLines.length);
  for (var i = 0; i < length; i++) {
    if (i >= actualLines.length) {
      // Missing output.
      failed = true;
      results.add('? ${expectedLines[i]}');
    } else if (i >= expectedLines.length) {
      // Unexpected extra output.
      failed = true;
      results.add('X ${actualLines[i]}');
    } else {
      var expectedLine = expectedLines[i].trim();
      var actualLine = actualLines[i].trim();

      if (expectedLine != actualLine) {
        // Mismatched lines.
        failed = true;
        results.add('X ${actualLines[i]}');
      } else {
        // Output is OK, but include it in case other lines are wrong.
        results.add('| ${actualLines[i]}');
      }
    }
  }

  // If any lines mismatched, show the expected and actual.
  if (failed) {
    failures.add('Expected $pipe:');
    failures.addAll(expectedLines.map((line) => '| $line'));
    failures.add('Got:');
    failures.addAll(results);
  }
}

/// Validates that [actualText] is a string of JSON that matches [expected],
/// which may be a literal JSON object, or any other [Matcher].
void _validateOutputJson(
  List<String> failures,
  String pipe,
  Object? expected,
  String actualText,
) {
  late Map actual;
  try {
    actual = jsonDecode(actualText) as Map;
  } on FormatException {
    failures.add('Expected $pipe JSON:');
    failures.add(expected.toString());
    failures.add('Got invalid JSON:');
    failures.add(actualText);
  }

  // Remove dart2js's timing logs, which would otherwise cause tests to fail
  // flakily when compilation takes a long time.
  actual['log']?.removeWhere(
    (entry) =>
        entry['level'] == 'Fine' &&
        (entry['message'] as String).startsWith('Not yet complete after'),
  );

  // Match against the expectation.
  expect(actual, expected);
}

/// A function that creates a [Validator] subclass.
typedef ValidatorCreator = Validator Function();

/// Schedules a single [Validator] to run on the [appPath].
///
/// Returns a scheduled Future that contains the validator after validation.
Future<Validator> validatePackage(ValidatorCreator fn, int? size) async {
  var cache = SystemCache(rootDir: _pathInSandbox(cachePath));
  final entrypoint = Entrypoint(_pathInSandbox(appPath), cache);
  var validator = fn();
  validator.context = ValidationContext(
    entrypoint,
    await Future.value(size ?? 100),
    _globalServer == null
        ? Uri.parse('https://pub.dev')
        : Uri.parse(globalServer.url),
    entrypoint.root.listFiles(),
  );
  await validator.validate();
  return validator;
}

/// Returns a matcher that asserts that a string contains [times] distinct
/// occurrences of [pattern], which must be a regular expression pattern.
Matcher matchesMultiple(String pattern, int times) {
  var buffer = StringBuffer(pattern);
  for (var i = 1; i < times; i++) {
    buffer.write(r'(.|\n)*');
    buffer.write(pattern);
  }
  return matches(buffer.toString());
}

/// A [StreamMatcher] that matches multiple lines of output.
StreamMatcher emitsLines(String output) => emitsInOrder(output.split('\n'));

/// Removes output from pub known to be unstable across runs or platforms.
String filterUnstableText(String input) {
  // Any paths in output should be relative to the sandbox and with forward
  // slashes to be stable across platforms.
  input = input.replaceAll(d.sandbox, r'$SANDBOX');
  input =
      input.replaceAllMapped(RegExp(r'\\(\S|\.)'), (match) => '/${match[1]}');
  var port = _globalServer?.port;
  if (port != null) {
    input = input.replaceAll(port.toString(), '\$PORT');
  }
  return input;
}

/// Runs `pub outdated [args]` and appends the output to [buffer].
Future<void> runPubIntoBuffer(
  List<String> args,
  StringBuffer buffer, {
  Map<String, String?>? environment,
  String? workingDirectory,
  String? stdin,
}) async {
  final process = await startPub(
    args: args,
    environment: environment,
    workingDirectory: workingDirectory,
  );
  if (stdin != null) {
    process.stdin.write(stdin);
    await process.stdin.flush();
    await process.stdin.close();
  }
  final exitCode = await process.exitCode;

  // TODO(jonasfj): Clean out temporary directory names from env vars...
  // if (workingDirectory != null) {
  //   buffer.writeln('\$ cd $workingDirectory');
  // }
  // if (environment != null && environment.isNotEmpty) {
  //   buffer.writeln(environment.entries
  //       .map((e) => '\$ export ${e.key}=${e.value}')
  //       .join('\n'));
  // }
  final pipe = stdin == null ? '' : ' echo ${escapeShellArgument(stdin)} |';
  buffer.writeln(
    '\$$pipe pub ${args.map(filterUnstableText).map(escapeShellArgument).join(' ')}',
  );
  for (final line in await process.stdout.rest.toList()) {
    buffer.writeln(filterUnstableText(line));
  }
  for (final line in await process.stderr.rest.toList()) {
    buffer.writeln('[STDERR] ${filterUnstableText(line)}');
  }
  if (exitCode != 0) {
    buffer.writeln('[EXIT CODE] $exitCode');
  }
  buffer.write('\n');
}

/// The current global [PackageServer].
PackageServer get globalServer => _globalServer!;
PackageServer? _globalServer;

/// Creates an HTTP server that replicates the structure of pub.dev and makes it
/// the current [globalServer].
Future<PackageServer> servePackages() async {
  final server = await startPackageServer();
  _globalServer = server;

  addTearDown(() {
    _globalServer = null;
  });
  return server;
}

Future<PackageServer> startPackageServer() async {
  final server = await PackageServer.start();

  addTearDown(() async {
    await server.close();
  });
  return server;
}

/// Create temporary folder 'bin/' containing a 'git' script in [sandbox]
/// By adding the bin/ folder to the search `$PATH` we can prevent `pub` from
/// detecting the installed 'git' binary and we can test that it prints
/// a useful error message.
Future<void> setUpFakeGitScript({
  required String bash,
  required String batch,
}) async {
  await d.dir('bin', [
    if (!Platform.isWindows) d.file('git', bash),
    if (Platform.isWindows) d.file('git.bat', batch),
  ]).create();
  if (!Platform.isWindows) {
    // Make the script executable.
    await runProcess('chmod', ['+x', p.join(d.sandbox, 'bin', 'git')]);
  }
}

/// Returns an environment where PATH is extended with `$sandbox/bin`.
Map<String, String> extendedPathEnv() {
  final separator = Platform.isWindows ? ';' : ':';
  final binFolder = p.join(d.sandbox, 'bin');

  return {
    // Override 'PATH' to ensure that we can't detect a working "git" binary
    'PATH': '$binFolder$separator${Platform.environment['PATH']}',
  };
}

Stream<List<int>> tarFromDescriptors(Iterable<d.Descriptor> contents) {
  final entries = <TarEntry>[];
  void addDescriptor(d.Descriptor descriptor, String path) {
    if (descriptor is d.DirectoryDescriptor) {
      for (final e in descriptor.contents) {
        addDescriptor(e, p.posix.join(path, descriptor.name));
      }
    } else {
      entries.add(
        TarEntry(
          TarHeader(
            // Ensure paths in tar files use forward slashes
            name: p.posix.join(path, descriptor.name),
            // We want to keep executable bits, but otherwise use the default
            // file mode
            mode: 420,
            // size: 100,
            modified: DateTime.fromMicrosecondsSinceEpoch(0),
            userName: 'pub',
            groupName: 'pub',
          ),
          (descriptor as d.FileDescriptor).readAsBytes(),
        ),
      );
    }
  }

  for (final e in contents) {
    addDescriptor(e, '');
  }
  return _replaceOs(
    Stream.fromIterable(entries)
        .transform(tarWriterWith(format: OutputFormat.gnuLongName))
        .transform(gzip.encoder),
  );
}

/// Replaces the entry at index 9 in [stream] with a 0. This replaces the os
/// entry of a gzip stream, giving us the same stream and this stable testing
/// on all platforms.
///
/// See https://www.rfc-editor.org/rfc/rfc1952 section 2.3 for information
/// about the OS header.
Stream<List<int>> _replaceOs(Stream<List<int>> stream) async* {
  final bytesBuilder = BytesBuilder();
  await for (final t in stream) {
    bytesBuilder.add(t);
  }
  final result = bytesBuilder.toBytes();
  result[9] = 0;
  yield result;
}
