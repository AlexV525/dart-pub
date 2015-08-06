// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:scheduled_test/scheduled_test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

const SCRIPT = """
main() {
  int a = true;
  print("no checks");
}
""";

main() {
  integration('runs a script in unchecked mode by default', () {
    servePackages((builder) {
      builder.serve("foo", "1.0.0", contents: [
        d.dir("bin", [
          d.file("script.dart", SCRIPT)
        ])
      ]);
    });

    schedulePub(args: ["global", "activate", "foo"]);

    var pub = pubRun(global: true, args: ["foo:script"]);
    pub.stdout.expect("no checks");
    pub.shouldExit();
  });
}
