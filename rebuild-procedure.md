# Triggering rebuilds in a package repository

This describes how a package repository can use abitools to rebuild packages
as soon as one of their dependencies makes a breaking change, and only then.
It is written for [r-universe](https://r-universe.dev), but applies to any
system that builds binary packages from source.

## What to store for each build

Run `abi_list(pkg, flags = install_flags("00install.log"))` right after the
package has been installed in the build environment, using the same library
that it was built against. The flags are the include directories of system
libraries from the install log, which some headers need to parse. It returns
the ABI exports and imports of the package:

- **exports**: the hashes of the S4 classes, C functions, and C headers of
  the package itself. Dependents are compared against these.
- **imports**: the exports of its critical dependencies that the package
  copied when it was built: the classes that it extends, the C functions of
  `C API` dependencies that it calls, and the headers of `linked library`
  dependencies.

Store it with the package metadata. Both are flat data frames, so
`jsonlite::toJSON()` gives lists of entries that are easy to query. For
example, part of the output for Rsamtools:

```js
_abi: {
  exports: [
    {key: 'Rsamtools::BamFile', hash: 'fbf800fa72e1dad8'},
    ...
  ],
  imports: [
    {key: 'S4Vectors::_new_IntAE()', hash: '26bbe984d9003e07'},
    {key: 'S4Vectors::List', hash: '90a253151dc8db9b'},
    {key: 'S4Vectors::Vector', hash: '09cab0bd77ae353b'},
    ...
  ]
}
```

The key is `<package>::<class>` for an S4 class, `<package>::<function>()`
for a C function, and `<package>/include` for the C headers. An import is
identical to the export it was copied from, as long as that has not changed.

Version numbers are not used: most version bumps do not change anything that
dependents copy. Code that a package copied from a dependency (such as
`f <- dep:::helper`) has no hash. This is rare, and usually only breaks if the
copied helper calls internals of the dependency that were removed later, so it
is left to the periodic rebuilds that the repository does anyway (r-universe
rebuilds every package at least once a month).

The output from one platform is enough: the hashes are identical on Linux and
macOS, except for C++ functions with types from the standard library.

## After a package is deployed

Suppose a new version of S4Vectors changes the `Vector` and `List` classes.

### 1. Diff the old and new exports

Fetch the exports of the previous build of the package before replacing it,
and compare them with the new ones, per class, per C function, and for the
headers. If
nothing changed, stop. This is the case for most deployments, including
version bumps without code changes, such as the twice-yearly version bump of
all Bioconductor packages.

### 2. Find the affected dependents

Query the packages that import one of the changed keys:

```js
{'_abi.imports.key': {$in: ['S4Vectors::Vector', 'S4Vectors::List']}}
```

Packages that only extend other classes of S4Vectors, such as `Rle` or
`DataFrame`, are not affected.

### 3. Rebuild only the first layer

S4 inheritance is transitive: the stored definition of a class includes all
of its superclasses. So the query above finds IRanges (`Ranges` extends
`Vector`), but also GenomicRanges (`GRanges` extends `IRanges::Ranges`, which
extends `Vector`).

Rebuilding both at once is wrong: GenomicRanges would be built against the
old IRanges, and need another rebuild once IRanges is updated. Therefore, skip
the affected packages that also have a critical dependency on another affected
package.

In the example, only IRanges is rebuilt. When its new build is deployed, the
hash of its `Ranges` class has changed, because it includes the inherited
slots of `Vector`. Step 1 and 2 then run for IRanges, and find GenomicRanges.
This way, the rebuilds propagate through the dependency graph one layer per
deployment, and each package is rebuilt exactly once, without any scheduling
logic.

## Nightly sweep

Rebuilds triggered by deployments can be missed:

- A rebuild of a package in the middle fails, so the next layer is never
  triggered.
- A change that does not affect the hash of subclasses, such as a class
  becoming virtual.
- Packages that were built before abitools was introduced, or of
  which the trigger was lost.

As a safety net, a nightly job checks the imports of each package against the
current exports of its dependencies (as `abi_check()` does), and rebuilds the
packages with differences, again skipping those that depend on another package
that needs a rebuild.

## Throttling

A real change in a core class can legitimately affect hundreds of packages.
The triggers should go into a rate-limited queue rather than a hard limit on
the number of dependents.

## Implementation in r-universe

What would need to change:

- **Build**: run `abi_list()` in the build job, and deploy the result with
  the package metadata.
- **cranlike-server**: store it (e.g. `_abi`), add an index on
  `_abi.imports.key`, and an endpoint that returns the affected dependents
  for a list of changed keys.
- **Deploy workflow**: replace the `version_change` check in
  [`version.sh`](https://github.com/r-universe-org/actions/blob/v12/deploy-packages/version.sh)
  by the diff of the exports, and let the `rechecks` job trigger the first layer
  of affected dependents. This also makes it possible to enable rebuilds for
  the Bioconductor universes again, see
  [help#740](https://github.com/r-universe-org/help/issues/740).
- **rebuilds**: a nightly job for the sweep, and a queue instead of the limit
  of 50 dependents in `trigger_revdeps()`.
