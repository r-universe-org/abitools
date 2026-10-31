# abitools

> Fingerprint the ABI of installed R packages

A binary R package can depend on the binary interface (ABI) of its
dependencies in two ways:

- **Cached S4 classes.** The definition of a class that extends a class from
  another package is stored in the lazy-load database at install time,
  including all inherited slots and superclasses. If the superclass changes,
  the stored subclass is inconsistent. The package may also store copies of
  classes of other packages (e.g. class unions it added members to), which
  replace the current definitions when it is loaded.
- **Cross-package C calls.** Packages call C functions of a `LinkingTo`
  dependency through `R_GetCCallable("pkg", "fun")`, compiled against the
  function signatures and struct layouts in its headers (or link to a shared
  library that it ships, e.g. TBB in RcppParallel).

abitools computes fingerprints of exactly these parts, to pinpoint which ABIs
have changed and therefore which dependents need to be rebuilt. The
**exports** of a package are hashes of the S4 classes, C functions, and C
headers that it provides. The **imports** of a package are the exports of its
dependencies that it was built against. Both are read from the installed
package: the class definitions from its lazy-load database, the names of the
packages and C functions it calls from the strings in its shared library, and
the signatures of C functions from its headers, parsed with libclang.

abitools can be used in two ways:

1. **Review a release.** Compare the exports of a new version of a package
   with those of the previous version, to see which classes and C functions
   changed their ABI or were removed. This tells authors whether a release may
   require rebuilding dependents.
2. **Find stale dependents.** Compare the current exports of a package with
   the imports that its dependents recorded when they were built. A dependent
   needs to be rebuilt if it imports a class or C function that has changed or
   was removed since. This is what package repositories need.

## Usage

`abi_list()` returns the exports and imports of an installed package. Run it
right after the package was built, in the library that it was built with.

```r
abi_list("minqa")
#> $exports
#> [1] key  hash
#> <0 rows> (or 0-length row.names)
#>
#> $imports
#>                              key             hash
#> 1 Rcpp::Rcpp_precious_preserve() 33a97ea62b293da6
#> 2   Rcpp::Rcpp_precious_remove() 63d26947ba7e1377
#> 3               Rcpp::demangle() ae88df8ffb66ca8d
#> 4   Rcpp::rcpp_get_stack_trace() c684a9bbe15cdc52
#> 5   Rcpp::rcpp_set_stack_trace() 33a97ea62b293da6
```

Keys are `<package>::<class>` for S4 classes, `<package>::<function>()` for C
functions, and `<package>/include` for headers. An import is a copy of the
export it was built against, so both are flat data frames with the same
columns, which `jsonlite::toJSON()` turns into lists of entries that are easy
to store and query:

```json
{
  "exports": [{"key": "Rsamtools::ApplyPileupsParam", "hash": "ca6334264a0e4b9c"}, ...],
  "imports": [{"key": "S4Vectors::Vector", "hash": "09cab0bd77ae353b"}, ...]
}
```

`abi_check()` compares imports with exports, and returns what changed or was
removed (no rows means nothing changed).

### Review a release

Pass the exports of the previous version as imports:

```r
abi_check(list(imports = old$exports), exports = new$exports)
#>   package                            reason
#>    Matrix                C headers changed
#>    Matrix C function cholmod_nnz() changed
```

Here, `C headers changed` only means that some file in the `include`
directory changed; the C functions show whether this affects the ABI.

### Find stale dependents

Pass the stored `abi_list()` of a dependent. The current exports of its
dependencies are computed from the installed packages, or can be passed as
`exports` (e.g. from a repository API):

```r
abi_check(x)
#>     package                 reason
#>   S4Vectors S4 class Vector changed
```

### Other functions

`abi_deps()` shows why a dependency is critical: `S4 class`, `C API`,
`linked library`, `headers` (header-only or static libraries, compiled into
the binary, so not critical), or `copied code` (see limitations).
`stale_classes()` checks the S4 classes of a package in a local library
against the current definitions of their superclasses, without stored imports.

See [rebuild-procedure.md](rebuild-procedure.md) for using this in a package
repository.

## What is hashed

The exact formats and rules are specified in [SPEC.md](SPEC.md), such that
other implementations can reproduce the hashes. The specification is a draft
and subject to change: hashes may differ between versions of abitools.

**S4 classes:** the class name, the virtual flag, and the slots and
superclasses (including inherited ones) with their packages. A dependent
imports the classes that it extends.

**C functions:** every function that a package registers with
`R_RegisterCCallable()`. R keeps no list of these, so abitools tries the
identifiers that occur both in the headers and as strings in the shared
library. A dependent imports the functions whose names appear as strings in
its shared library (the names that it passes to `R_GetCCallable()`).

The hash describes the signature of the function, as parsed from the headers
of the package by libclang (with the preprocessor, and the include directories
of R and of the package's own `LinkingTo` dependencies): the canonical types
of the return value and parameters, and for structs defined in these headers
their size, alignment and field offsets. Names, qualifiers, formatting, and
macros do not matter; a changed array size from a `#define` or a reordered
field does. For example, for `S4Vectors::_new_IntAE()`:

```
function(UInt64,UInt64,Int32)->*{24,8|0:UInt64;64:UInt64;128:*Int32;}
```

The signature is taken from the cast at a call site of `R_GetCCallable()` in
the headers if there is one, else from a declaration. This covers the
different ways in which packages declare a C API: plain declarations (cli,
xts), macros as return type (nloptr), stub prefixes such as `_fun` (Bioconductor),
`_pkg_fun` (Rcpp interfaces) or `M_fun` (Matrix), function pointers (libgeos,
PreciseSums), and casts at call sites (Rcpp, Matrix, RNifti). Functions that
are not found in the headers are not exported. Set
`options(abitools.verbose = TRUE)` to see why a header could not be parsed.

**Headers:** a hash of all files in the `include` directory, used for
`linked library` dependencies.

## Validation

- **Rcpp** 1.0.10 to 1.1.2: the headers changed in every release, but the
  signatures of its 36 C functions did not, so none of these releases would
  trigger rebuilds. Rcpp packages import only the few functions they call
  (e.g. 5 for minqa).
- **Matrix** records an ABI version in its headers, which it increased in
  1.6-2 and 1.7-0. From 1.6-0 to 1.7-3, signatures changed in exactly these
  releases: in 1.6-2 the parameters of `cholmod_band_inplace()` and
  `cholmod_solve2()` and the return type of `cholmod_nnz()`, and in 1.7-0 (the
  update to CHOLMOD 5) the size of the `cholmod_common` struct.
- **Bioconductor**, release to devel: the only change in the S4 classes of
  S4Vectors, IRanges, BiocGenerics, S4Arrays, and DelayedArray was the removal
  of two classes from S4Vectors that no other package extends.
- **Stability:** libclang 17 to 22 give identical signatures for all 1290
  registered C functions of 18 packages. Linux and macOS give identical
  signatures, except for C++ functions with types from the C++ standard
  library (e.g. `std::string`), which differ between libc++ and libstdc++.

## Installation

abitools requires libclang: `apt-get install libclang-dev` (Debian, Ubuntu),
`dnf install clang-devel` (Fedora), or `brew install llvm` (macOS). Set
`LLVM_CONFIG` to choose an LLVM installation. There is no Windows build; the
fingerprints of one platform are enough for a repository (see limitations).

## Limitations

- Inspecting a package loads the namespaces that its lazy-load database refers
  to, and the package itself if it registers C functions. Run it in the
  library that the package was built with, and compare results only within
  the same platform and R version. Signatures that only differ on another
  platform (e.g. a struct with an `#ifdef _WIN32` member) are not detected.
- C functions that are registered but not found in the headers (e.g. in an
  inactive `#ifdef` branch, or of packages without headers) are not exported.
  For the C APIs that Bioconductor packages use via `LinkingTo`, all functions
  that are called are found.
- Calls to `R_GetCCallable()` of a package that is not in `LinkingTo` are not
  imports, on purpose. Such packages declare the functions themselves (e.g.
  dplyr for vctrs, SNPRelate for SeqArray), so a rebuild would not pick up a
  changed signature: that requires a change in their source. The survey lists
  these packages.
- The class hash ignores prototypes and validity methods, and the methods of
  reference classes (the inherited methods are copied into the subclass, which
  `abi_deps()` reports as `copied code`).
- Code that a package copies from a dependency at install time (e.g.
  `f <- dep:::helper`, ggproto or S7 objects) is reported by `abi_deps()` but
  not hashed. Methods for generics of other packages are registered at load
  time, and are not ABI sensitive.
