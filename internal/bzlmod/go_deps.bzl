# Copyright 2023 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//internal:go_repository.bzl", "go_repository")
load(":go_mod.bzl", "deps_from_go_mod", "sums_from_go_mod")
load(
    ":default_gazelle_overrides.bzl",
    "DEFAULT_BUILD_EXTRA_ARGS_BY_PATH",
    "DEFAULT_BUILD_FILE_GENERATION_BY_PATH",
    "DEFAULT_DIRECTIVES_BY_PATH",
)
load(":semver.bzl", "semver")
load(
    ":utils.bzl",
    "drop_nones",
    "format_rule_call",
    "get_directive_value",
    "with_replaced_or_new_fields",
)

visibility("//")

_HIGHEST_VERSION_SENTINEL = semver.to_comparable("999999.999999.999999")

_FORBIDDEN_OVERRIDE_TAG = """\
Using the "go_deps.{tag_class}" tag in a non-root Bazel module is forbidden, \
but module "{module_name}" requests it.

If you need this override for a Bazel module that will be available in a public \
registry (such as the Bazel Central Registry), please file an issue at \
https://github.com/bazelbuild/bazel-gazelle/issues/new or submit a PR adding \
the required directives to the "default_gazelle_overrides.bzl" file at \
https://github.com/bazelbuild/bazel-gazelle/tree/master/internal/bzlmod/default_gazelle_overrides.bzl.
"""

_GAZELLE_ATTRS = {
    "build_file_generation": attr.string(
        default = "on",
        doc = """One of `"auto"`, `"on"` (default), `"off"`.

        Whether Gazelle should generate build files for the Go module.

        Although "auto" is the default globally for build_file_generation,
        if a `"gazelle_override"` or `"gazelle_default_attributes"` tag is present
        for a Go module, the `"build_file_generation"` attribute will default to "on"
        since these tags indicate the presence of `"directives"` or `"build_extra_args"`.

        In `"auto"` mode, Gazelle will run if there is no build file in the Go
        module's root directory.

        """,
        values = [
            "auto",
            "off",
            "on",
        ],
    ),
    "build_extra_args": attr.string_list(
        default = [],
        doc = """
        A list of additional command line arguments to pass to Gazelle when generating build files.
        """,
    ),
    "directives": attr.string_list(
        doc = """Gazelle configuration directives to use for this Go module's external repository.

        Each directive uses the same format as those that Gazelle
        accepts as comments in Bazel source files, with the
        directive name followed by optional arguments separated by
        whitespace.""",
    ),
}

def _fail_on_non_root_overrides(module_ctx, module, tag_class):
    if module.is_root:
        return

    # Isolated module extension usages only contain tags from a single module, so we can allow
    # overrides. This is a new feature in Bazel 6.3.0, earlier versions do not allow module usages
    # to be isolated.
    if getattr(module_ctx, "is_isolated", False):
        return

    if getattr(module.tags, tag_class):
        fail(_FORBIDDEN_OVERRIDE_TAG.format(
            tag_class = tag_class,
            module_name = module.name,
        ))

def _fail_on_duplicate_overrides(path, module_name, overrides):
    if path in overrides:
        fail("Multiple overrides defined for Go module path \"{}\" in module \"{}\".".format(path, module_name))

def _fail_on_unmatched_overrides(override_keys, resolutions, override_name):
    unmatched_overrides = [path for path in override_keys if path not in resolutions]
    if unmatched_overrides:
        fail("Some {} did not target a Go module with a matching path: {}".format(
            override_name,
            ", ".join(unmatched_overrides),
        ))

def _check_directive(directive):
    if directive.startswith("gazelle:") and " " in directive and not directive[len("gazelle:"):][0].isspace():
        return
    fail("Invalid Gazelle directive: \"{}\". Gazelle directives must be of the form \"gazelle:key value\".".format(directive))

def _get_override_or_default(specific_overrides, gazelle_default_attributes, default_path_overrides, path, default_value, attribute_name):
    # 1st: Check for user-provided specific overrides. If a specific override is found,
    # all of its attributes will be applied (even if left to the tag's default). This is to allow
    # users to override the gazelle_default_attributes tag back to the tag's default.
    #
    # This will also cause "build_file_generation" to default to "on" if a specific override is found.
    specific_override = specific_overrides.get(path)
    if specific_override and hasattr(specific_override, attribute_name):
        return getattr(specific_override, attribute_name)

    # 2nd. Check for default attributes provided by the user. This must be done before checking for
    # gazelle's defaults path overrides to prevent Gazelle from overriding a user-specified flag.
    #
    # This will also cause "build_file_generation" to default to "on" if default attributes are found.
    global_override_value = getattr(gazelle_default_attributes, attribute_name, None)
    if global_override_value:
        return global_override_value

    # 3rd: Check for default overrides for specific path.
    default_path_override = default_path_overrides.get(path)
    if default_path_override:
        return default_path_override

    # 4th. Return the default value if no override was found.
    # This will cause "build_file_generation" to default to "auto".
    return default_value

def _get_directives(path, gazelle_overrides, gazelle_default_attributes):
    return _get_override_or_default(gazelle_overrides, gazelle_default_attributes, DEFAULT_DIRECTIVES_BY_PATH, path, [], "directives")

def _get_build_file_generation(path, gazelle_overrides, gazelle_default_attributes):
    # The default value for build_file_generation is "auto" if no override is found, but will default to "on" if an override is found.
    return _get_override_or_default(gazelle_overrides, gazelle_default_attributes, DEFAULT_BUILD_FILE_GENERATION_BY_PATH, path, "auto", "build_file_generation")

def _get_build_extra_args(path, gazelle_overrides, gazelle_default_attributes):
    return _get_override_or_default(gazelle_overrides, gazelle_default_attributes, DEFAULT_BUILD_EXTRA_ARGS_BY_PATH, path, [], "build_extra_args")

def _get_patches(path, module_overrides):
    return _get_override_or_default(module_overrides, struct(), {}, path, [], "patches")

def _get_patch_args(path, module_overrides):
    override = _get_override_or_default(module_overrides, struct(), {}, path, None, "patch_strip")
    return ["-p{}".format(override)] if override else []

def _repo_name(importpath):
    path_segments = importpath.split("/")
    segments = reversed(path_segments[0].split(".")) + path_segments[1:]
    candidate_name = "_".join(segments).replace("-", "_")
    return "".join([c.lower() if c.isalnum() else "_" for c in candidate_name.elems()])

def _is_dev_dependency(module_ctx, tag):
    if hasattr(tag, "_is_dev_dependency"):
        # Synthetic tags generated from go_deps.from_file have this "hidden" attribute.
        return tag._is_dev_dependency

    # This function is available in Bazel 6.2.0 and later. This is the same version that has
    # module_ctx.extension_metadata, so the return value of this function is not used if it is
    # not available.
    return module_ctx.is_dev_dependency(tag) if hasattr(module_ctx, "is_dev_dependency") else False

# This function processes the gazelle_default_attributes tag for a given module and returns a struct
# containing the attributes from _GAZELLE_ATTRS that are defined in the tag.
def _process_gazelle_default_attributes(module_ctx):
    for module in module_ctx.modules:
        _fail_on_non_root_overrides(module_ctx, module, "gazelle_default_attributes")

    for module in module_ctx.modules:
        tags = module.tags.gazelle_default_attributes
        if not tags:
            continue

        if len(tags) > 1:
            fail(
                "go_deps.gazelle_default_attributes: only one tag can be specified per module, got:\n",
                *[t for p in zip(module.tags.gazelle_default_attributes, len(module.tags.gazelle_default_attributes) * ["\n"]) for t in p]
            )

        tag = tags[0]
        return struct(**{
            attr: getattr(tag, attr)
            for attr in _GAZELLE_ATTRS.keys()
            if hasattr(tag, attr)
        })

    return None

# This function processes a given override type for a given module, checks for duplicate overrides
# and inserts the override returned from the process_override_func into the overrides dict.
def _process_overrides(module_ctx, module, override_type, overrides, process_override_func, additional_overrides = None):
    _fail_on_non_root_overrides(module_ctx, module, override_type)
    for override_tag in getattr(module.tags, override_type):
        _fail_on_duplicate_overrides(override_tag.path, module.name, overrides)

        # Some overrides conflict with other overrides. These can be specified in the
        # additional_overrides dict. If the override is in the additional_overrides dict, then fail.
        if additional_overrides:
            _fail_on_duplicate_overrides(override_tag.path, module.name, additional_overrides)

        overrides[override_tag.path] = process_override_func(override_tag)

def _process_gazelle_override(gazelle_override_tag):
    for directive in gazelle_override_tag.directives:
        _check_directive(directive)

    return struct(**{
        attr: getattr(gazelle_override_tag, attr)
        for attr in _GAZELLE_ATTRS.keys()
        if hasattr(gazelle_override_tag, attr)
    })

def _process_module_override(module_override_tag):
    return struct(
        patches = module_override_tag.patches,
        patch_strip = module_override_tag.patch_strip,
    )

def _process_archive_override(archive_override_tag):
    return struct(
        urls = archive_override_tag.urls,
        sha256 = archive_override_tag.sha256,
        strip_prefix = archive_override_tag.strip_prefix,
        patches = archive_override_tag.patches,
        patch_strip = archive_override_tag.patch_strip,
    )

def _extension_metadata(module_ctx, *, root_module_direct_deps, root_module_direct_dev_deps):
    if not hasattr(module_ctx, "extension_metadata"):
        return None
    return module_ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_deps,
        root_module_direct_dev_deps = root_module_direct_dev_deps,
    )

def _go_repository_config_impl(ctx):
    repos = []
    for name, importpath in sorted(ctx.attr.importpaths.items()):
        repos.append(format_rule_call(
            "go_repository",
            name = name,
            importpath = importpath,
            module_name = ctx.attr.module_names.get(name),
            build_naming_convention = ctx.attr.build_naming_conventions.get(name),
        ))

    ctx.file("WORKSPACE", "\n".join(repos))
    ctx.file("BUILD.bazel", "exports_files(['WORKSPACE'])")

_go_repository_config = repository_rule(
    implementation = _go_repository_config_impl,
    attrs = {
        "importpaths": attr.string_dict(mandatory = True),
        "module_names": attr.string_dict(mandatory = True),
        "build_naming_conventions": attr.string_dict(mandatory = True),
    },
)

def _noop(_):
    pass

# These repos are shared between the isolated and non-isolated instances of go_deps as they are
# referenced directly by rules (go_proto_library) and would result in linker errors due to duplicate
# packages if they were resolved separately.
# When adding a new Go module to this list, make sure that:
# 1. The corresponding repository is visible to the gazelle module via a use_repo directive.
# 2. All transitive dependencies of the module are also in this list. Avoid adding module that have
#    a large number of transitive dependencies.
_SHARED_REPOS = [
    "github.com/golang/protobuf",
    "google.golang.org/protobuf",
]

def _go_deps_impl(module_ctx):
    module_resolutions = {}
    sums = {}
    replace_map = {}
    bazel_deps = {}

    gazelle_default_attributes = _process_gazelle_default_attributes(module_ctx)
    archive_overrides = {}
    gazelle_overrides = {}
    module_overrides = {}

    root_versions = {}
    root_module_direct_deps = {}
    root_module_direct_dev_deps = {}

    if module_ctx.modules[0].name == "gazelle":
        root_module_direct_deps["bazel_gazelle_go_repository_config"] = None

    outdated_direct_dep_printer = print
    for module in module_ctx.modules:
        # Parse the go_deps.config tag of the root module only.
        for mod_config in module.tags.config:
            if not module.is_root:
                continue
            check_direct_deps = mod_config.check_direct_dependencies
            if check_direct_deps == "off":
                outdated_direct_dep_printer = _noop
            elif check_direct_deps == "warning":
                outdated_direct_dep_printer = print
            elif check_direct_deps == "error":
                outdated_direct_dep_printer = fail

        _process_overrides(module_ctx, module, "gazelle_override", gazelle_overrides, _process_gazelle_override)
        _process_overrides(module_ctx, module, "module_override", module_overrides, _process_module_override, archive_overrides)
        _process_overrides(module_ctx, module, "archive_override", archive_overrides, _process_archive_override, module_overrides)

        if len(module.tags.from_file) > 1:
            fail(
                "Multiple \"go_deps.from_file\" tags defined in module \"{}\": {}".format(
                    module.name,
                    ", ".join([str(tag.go_mod) for tag in module.tags.from_file]),
                ),
            )
        additional_module_tags = []
        for from_file_tag in module.tags.from_file:
            module_path, module_tags_from_go_mod, go_mod_replace_map = deps_from_go_mod(module_ctx, from_file_tag.go_mod)
            is_dev_dependency = _is_dev_dependency(module_ctx, from_file_tag)
            additional_module_tags += [
                with_replaced_or_new_fields(tag, _is_dev_dependency = is_dev_dependency)
                for tag in module_tags_from_go_mod
            ]

            if module.is_root or getattr(module_ctx, "is_isolated", False):
                replace_map.update(go_mod_replace_map)
            else:
                # Register this Bazel module as providing the specified Go module. It participates
                # in version resolution using its registry version, which uses a relaxed variant of
                # semver that can however still be compared to strict semvers.
                # An empty version string signals an override, which is assumed to be newer than any
                # other version.
                raw_version = _canonicalize_raw_version(module.version)
                version = semver.to_comparable(raw_version, relaxed = True) if raw_version else _HIGHEST_VERSION_SENTINEL
                if module_path not in bazel_deps or version > bazel_deps[module_path].version:
                    bazel_deps[module_path] = struct(
                        module_name = module.name,
                        repo_name = "@" + from_file_tag.go_mod.workspace_name,
                        version = version,
                        raw_version = raw_version,
                    )

            # Load all sums from transitively resolved `go.sum` files that have modules.
            if len(module_tags_from_go_mod) > 0:
                for entry, new_sum in sums_from_go_mod(module_ctx, from_file_tag.go_mod).items():
                    _safe_insert_sum(sums, entry, new_sum)

        # Load sums from manually specified modules separately.
        for module_tag in module.tags.module:
            if module_tag.build_naming_convention:
                fail("""The "build_naming_convention" attribute is no longer supported for "go_deps.module" tags. Use a "gazelle:go_naming_convention" directive via the "gazelle_override" tag's "directives" attribute instead.""")
            if module_tag.build_file_proto_mode:
                fail("""The "build_file_proto_mode" attribute is no longer supported for "go_deps.module" tags. Use a "gazelle:proto" directive via the "gazelle_override" tag's "directives" attribute instead.""")
            sum_version = _canonicalize_raw_version(module_tag.version)
            _safe_insert_sum(sums, (module_tag.path, sum_version), module_tag.sum)

        # Parse the go_dep.module tags of all transitive dependencies and apply
        # Minimum Version Selection to resolve importpaths to Go module versions
        # and sums.
        #
        # Note: This applies Minimum Version Selection on the resolved
        # dependency graphs of all transitive Bazel module dependencies, which
        # is not what `go mod` does. But since this algorithm ends up using only
        # Go module versions that have been explicitly declared somewhere in the
        # full graph, we can assume that at that place all its required
        # transitive dependencies have also been declared - we may end up
        # resolving them to higher versions, but only compatible ones.
        paths = {}
        for module_tag in module.tags.module + additional_module_tags:
            if module_tag.path in paths:
                fail("Duplicate Go module path \"{}\" in module \"{}\".".format(module_tag.path, module.name))
            if module_tag.path in bazel_deps:
                continue
            paths[module_tag.path] = None
            raw_version = _canonicalize_raw_version(module_tag.version)

            # For modules imported from a go.sum, we know which ones are direct
            # dependencies and can thus only report implicit version upgrades
            # for direct dependencies. For manually specified go_deps.module
            # tags, we always report version upgrades unless users override with
            # the "indirect" attribute.
            if module.is_root and not module_tag.indirect:
                root_versions[module_tag.path] = raw_version
                if _is_dev_dependency(module_ctx, module_tag):
                    root_module_direct_dev_deps[_repo_name(module_tag.path)] = None
                else:
                    root_module_direct_deps[_repo_name(module_tag.path)] = None

            version = semver.to_comparable(raw_version)
            if module_tag.path not in module_resolutions or version > module_resolutions[module_tag.path].version:
                module_resolutions[module_tag.path] = struct(
                    repo_name = _repo_name(module_tag.path),
                    version = version,
                    raw_version = raw_version,
                )

    _fail_on_unmatched_overrides(archive_overrides.keys(), module_resolutions, "archive_overrides")
    _fail_on_unmatched_overrides(gazelle_overrides.keys(), module_resolutions, "gazelle_overrides")
    _fail_on_unmatched_overrides(module_overrides.keys(), module_resolutions, "module_overrides")

    # All `replace` directives are applied after version resolution.
    # We can simply do this by checking the replace paths' existence
    # in the module resolutions and swapping out the entry.
    for path, replace in replace_map.items():
        if path in module_resolutions:
            # If the replace directive specified a version then we only
            # apply it if the versions match.
            if replace.from_version:
                comparable_from_version = semver.to_comparable(replace.from_version)
                if module_resolutions[path].version != comparable_from_version:
                    continue

            new_version = semver.to_comparable(replace.version)
            module_resolutions[path] = with_replaced_or_new_fields(
                module_resolutions[path],
                replace = replace.to_path,
                version = new_version,
                raw_version = replace.version,
            )
            if path in root_versions:
                if replace != replace.to_path:
                    # If the root module replaces a Go module with a completely different one, do
                    # not ever report an implicit version upgrade.
                    root_versions.pop(path)
                else:
                    root_versions[path] = replace.version

    for path, bazel_dep in bazel_deps.items():
        # We can't apply overrides to Bazel dependencies and thus fall back to using the Go module.
        if path in archive_overrides or path in gazelle_overrides or path in module_overrides or path in replace_map:
            continue

        # Only use the Bazel module if it is at least as high as the required Go module version.
        if path in module_resolutions and bazel_dep.version < module_resolutions[path].version:
            outdated_direct_dep_printer(
                "Go module \"{path}\" is provided by Bazel module \"{bazel_module}\" in version {bazel_dep_version}, but requested at higher version {go_version} via Go requirements. Consider adding or updating an appropriate \"bazel_dep\" to ensure that the Bazel module is used to provide the Go module.".format(
                    path = path,
                    bazel_module = bazel_dep.module_name,
                    bazel_dep_version = bazel_dep.raw_version,
                    go_version = module_resolutions[path].raw_version,
                ),
            )
            continue

        # TODO: We should update root_versions if the bazel_dep is a direct dependency of the root
        #   module. However, we currently don't have a way to determine that.
        module_resolutions[path] = bazel_dep

    for path, root_version in root_versions.items():
        if semver.to_comparable(root_version) < module_resolutions[path].version:
            outdated_direct_dep_printer(
                "For Go module \"{path}\", the root module requires module version v{root_version}, but got v{resolved_version} in the resolved dependency graph.".format(
                    path = path,
                    root_version = root_version,
                    resolved_version = module_resolutions[path].raw_version,
                ),
            )

    for path, module in module_resolutions.items():
        if hasattr(module, "module_name"):
            # Do not create a go_repository for a Go module provided by a bazel_dep.
            root_module_direct_deps.pop(_repo_name(path), default = None)
            root_module_direct_dev_deps.pop(_repo_name(path), default = None)
            continue
        if getattr(module_ctx, "is_isolated", False) and path in _SHARED_REPOS:
            # Do not create a go_repository for a dep shared with the non-isolated instance of
            # go_deps.
            continue

        go_repository_args = {
            "name": module.repo_name,
            "importpath": path,
            "build_directives": _get_directives(path, gazelle_overrides, gazelle_default_attributes),
            "build_file_generation": _get_build_file_generation(path, gazelle_overrides, gazelle_default_attributes),
            "build_extra_args": _get_build_extra_args(path, gazelle_overrides, gazelle_default_attributes),
            "patches": _get_patches(path, module_overrides),
            "patch_args": _get_patch_args(path, module_overrides),
        }

        archive_override = archive_overrides.get(path)
        if archive_override:
            go_repository_args.update({
                "urls": archive_override.urls,
                "strip_prefix": archive_override.strip_prefix,
                "sha256": archive_override.sha256,
                "patches": _get_patches(path, archive_overrides),
                "patch_args": _get_patch_args(path, archive_overrides),
            })
        else:
            go_repository_args.update({
                "sum": _get_sum_from_module(path, module, sums),
                "replace": getattr(module, "replace", None),
                "version": "v" + module.raw_version,
            })

        go_repository(**go_repository_args)

    # Create a synthetic WORKSPACE file that lists all Go repositories created
    # above and contains all the information required by Gazelle's -repo_config
    # to generate BUILD files for external Go modules. This skips the need to
    # run generate_repo_config. Only "importpath" and "build_naming_convention"
    # are relevant.
    _go_repository_config(
        name = "bazel_gazelle_go_repository_config",
        importpaths = {
            module.repo_name: path
            for path, module in module_resolutions.items()
        },
        module_names = {
            info.repo_name: info.module_name
            for path, info in bazel_deps.items()
        },
        build_naming_conventions = drop_nones({
            module.repo_name: get_directive_value(
                _get_directives(path, gazelle_overrides, gazelle_default_attributes),
                "go_naming_convention",
            )
            for path, module in module_resolutions.items()
        }),
    )

    return _extension_metadata(
        module_ctx,
        root_module_direct_deps = root_module_direct_deps.keys(),
        # If a Go module appears as both a dev and a non-dev dependency, it has to be imported as a
        # non-dev dependency.
        root_module_direct_dev_deps = {
            repo_name: None
            for repo_name in root_module_direct_dev_deps.keys()
            if repo_name not in root_module_direct_deps
        }.keys(),
    )

def _get_sum_from_module(path, module, sums):
    entry = (path, module.raw_version)
    if hasattr(module, "replace"):
        entry = (module.replace, module.raw_version)

    if entry not in sums:
        fail("No sum for {}@{} found".format(path, module.raw_version))

    return sums[entry]

def _safe_insert_sum(sums, entry, new_sum):
    if entry in sums and new_sum != sums[entry]:
        fail("Multiple mismatching sums for {}@{} found.".format(entry[0], entry[1]))
    sums[entry] = new_sum

def _canonicalize_raw_version(raw_version):
    if raw_version.startswith("v"):
        return raw_version[1:]
    return raw_version

_config_tag = tag_class(
    attrs = {
        "check_direct_dependencies": attr.string(
            values = ["off", "warning", "error"],
        ),
    },
)

_from_file_tag = tag_class(
    attrs = {
        "go_mod": attr.label(mandatory = True),
    },
)

_module_tag = tag_class(
    attrs = {
        "path": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sum": attr.string(),
        "indirect": attr.bool(
            doc = """Whether this Go module is an indirect dependency.""",
            default = False,
        ),
        "build_naming_convention": attr.string(doc = """Removed, do not use""", default = ""),
        "build_file_proto_mode": attr.string(doc = """Removed, do not use""", default = ""),
    },
)

_archive_override_tag = tag_class(
    attrs = {
        "path": attr.string(
            doc = """The Go module path for the repository to be overridden.

            This module path must be defined by other tags in this
            extension within this Bazel module.""",
            mandatory = True,
        ),
        "urls": attr.string_list(
            doc = """A list of HTTP(S) URLs where an archive containing the project can be
            downloaded. Bazel will attempt to download from the first URL; the others
            are mirrors.""",
        ),
        "strip_prefix": attr.string(
            doc = """If the repository is downloaded via HTTP (`urls` is set), this is a
            directory prefix to strip. See [`http_archive.strip_prefix`].""",
        ),
        "sha256": attr.string(
            doc = """If the repository is downloaded via HTTP (`urls` is set), this is the
            SHA-256 sum of the downloaded archive. When set, Bazel will verify the archive
            against this sum before extracting it.""",
        ),
        "patches": attr.label_list(
            doc = "A list of patches to apply to the repository *after* gazelle runs.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "The number of leading path segments to be stripped from the file name in the patches.",
        ),
    },
    doc = "Override the default source location on a given Go module in this extension.",
)

_gazelle_override_tag = tag_class(
    attrs = {
        "path": attr.string(
            doc = """The Go module path for the repository to be overridden.

            This module path must be defined by other tags in this
            extension within this Bazel module.""",
            mandatory = True,
        ),
    } | _GAZELLE_ATTRS,
    doc = "Override Gazelle's behavior on a given Go module defined by other tags in this extension.",
)

_gazelle_default_attributes_tag = tag_class(
    attrs = _GAZELLE_ATTRS,
    doc = "Override Gazelle's default attribute values for all modules in this extension.",
)

_module_override_tag = tag_class(
    attrs = {
        "path": attr.string(
            doc = """The Go module path for the repository to be overridden.

            This module path must be defined by other tags in this
            extension within this Bazel module.""",
            mandatory = True,
        ),
        "patches": attr.label_list(
            doc = "A list of patches to apply to the repository *after* gazelle runs.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "The number of leading path segments to be stripped from the file name in the patches.",
        ),
    },
    doc = "Apply patches to a given Go module defined by other tags in this extension.",
)

go_deps = module_extension(
    _go_deps_impl,
    tag_classes = {
        "archive_override": _archive_override_tag,
        "config": _config_tag,
        "from_file": _from_file_tag,
        "gazelle_override": _gazelle_override_tag,
        "gazelle_default_attributes": _gazelle_default_attributes_tag,
        "module": _module_tag,
        "module_override": _module_override_tag,
    },
)
