# Copyright (c) 2020 The DAML Authors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

load("@language_support_ts_deps//eslint:index.bzl", _eslint_test = "eslint_test")
load("@os_info//:os_info.bzl", "is_windows")

def eslint_test(name, srcs, tsconfig = ":tsconfig.json", package_json = ":package.json", data = [], **kwargs):
    """Run eslint on the given typescript source.

    Args:
      name: The name of the generated test rule.
      srcs: The source files to lint.
      tsconfig: The tsconfig.json file.
      package_json: The package.json file.
      data: Additional runtime dependencies.
    """
    eslint_deps = [
        "@language_support_ts_deps//@typescript-eslint",
        "@language_support_ts_deps//tsutils",
    ] if not is_windows else []
    templated_args = [
        "--ext",
        "ts",
        "--config",
        "$(rlocation $(location %s))" % package_json,
        '--parser-options={"tsconfigRootDir":"$(dirname $(rlocation $(location %s)))"}' % tsconfig,
    ]
    for src in srcs:
        templated_args.append("$(rlocation $(location %s))" % src)
    _eslint_test(
        name = name,
        data = srcs + [tsconfig, package_json] + data + eslint_deps,
        templated_args = templated_args,
        **kwargs
    ) if not is_windows else None
