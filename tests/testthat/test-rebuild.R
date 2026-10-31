test_that("a version bump without changes does not require a rebuild", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_provider(root, "1.0"), lib)
  install_pkg(make_consumer(root), lib)

  with_lib(lib, {
    deps <- abi_deps("conspkg")
    expect_equal(deps$package, rep("provpkg", 3))
    expect_equal(deps$type, c("S4 class", "copied code", "headers"))
    expect_equal(deps$detail, c("Base", "plus_one", ""))

    record <- abi_list("conspkg")
    expect_equal(record$exports$key, "conspkg::Derived")
    expect_equal(record$imports$key, "provpkg::Base")
    expect_equal(nrow(abi_check(record)), 0)
    fp1 <- abi_list("provpkg")
    expect_equal(fp1$exports$key, c("provpkg/include", "provpkg::Base", "provpkg::Other"))
    expect_equal(fp1$exports[2, ], record$imports, ignore_attr = TRUE)
    expect_equal(nrow(fp1$imports), 0)
  })

  # Same code, new version: nothing changed
  install_pkg(make_provider(root, "1.1"), lib)
  with_lib(lib, {
    expect_equal(abi_list("provpkg"), fp1)
    expect_equal(nrow(abi_check(record)), 0)
    expect_equal(nrow(stale_classes("conspkg")), 0)
  })
})

test_that("a changed superclass requires a rebuild", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_provider(root, "1.0"), lib)
  install_pkg(make_consumer(root), lib)
  record <- with_lib(lib, abi_list("conspkg"))

  install_pkg(make_provider(root, "1.0", slots = 'representation(x = "numeric", z = "integer")',
                            header = "#define PROV 2"), lib)
  with_lib(lib, {
    expect_equal(abi_check(record)$reason, "S4 class Base changed")
    stale <- stale_classes("conspkg")
    expect_equal(stale$class, "Derived")
    expect_equal(stale$reason, "slots of superclass changed")
  })

  # Exports can also be supplied by the caller, e.g. from a repository
  expect_equal(abi_check(record, exports = record$exports[0, ])$reason, "dependency not found")
})

test_that("packages without classes or headers have no exports", {
  x <- abi_list("tools")
  expect_equal(names(x$exports), c("key", "hash"))
  expect_equal(nrow(x$exports), 0)
  expect_equal(nrow(x$imports), 0)
})

test_that("empty imports and exports survive a JSON round trip", {
  skip_if_not_installed("jsonlite")
  x <- jsonlite::fromJSON(jsonlite::toJSON(abi_list("tools")))
  expect_equal(x$imports, list())
  expect_equal(nrow(abi_check(x)), 0)
  record <- list(imports = data.frame(key = "S4Vectors::Vector", hash = "10ab26d3"))
  expect_equal(abi_check(record, exports = list())$reason, "dependency not found")
})

test_that("imports and exports are stored as flat lists in JSON", {
  skip_on_cran()
  skip_if_not_installed("jsonlite")
  record <- list(
    exports = data.frame(key = "IRanges::Ranges", hash = "5f7f937e"),
    imports = data.frame(key = c("S4Vectors/include", "S4Vectors::Vector"), hash = c("1be3971f", "10ab26d3"))
  )
  json <- jsonlite::toJSON(record)
  expect_equal(as.character(json), paste0('{"exports":[{"key":"IRanges::Ranges","hash":"5f7f937e"}],',
                                          '"imports":[{"key":"S4Vectors/include","hash":"1be3971f"},',
                                          '{"key":"S4Vectors::Vector","hash":"10ab26d3"}]}'))
  exports <- data.frame(key = c("S4Vectors/include", "S4Vectors::List", "S4Vectors::Vector"),
                        hash = c("1be3971f", "7cded7a2", "10ab26d3"))
  expect_equal(nrow(abi_check(jsonlite::fromJSON(json), exports = exports)), 0)
  exports$hash[3] <- "changed"
  expect_equal(abi_check(jsonlite::fromJSON(json), exports = exports)$reason, "S4 class Vector changed")
  check <- abi_check(jsonlite::fromJSON(json), exports = exports[2:3, ])
  expect_equal(check$package, c("S4Vectors", "S4Vectors"))
  expect_equal(check$reason, c("C headers removed", "S4 class Vector changed"))
})

test_that("copies of classes of other packages are not exported", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_provider(root, "1.0"), lib)
  # Without importClassesFrom(), R stores a copy of Base in conspkg
  install_pkg(make_pkg(root, "conspkg", "1.0",
                       code = 'setClass("Derived", contains = "Base")',
                       namespace = c("import(methods)", "importFrom(provpkg, helper)",
                                     "exportClasses(Derived)"),
                       imports = "provpkg"), lib)
  with_lib(lib, {
    db <- abitools:::load_rdb(find.package("conspkg"), "conspkg")
    expect_true(exists(".__C__Base", envir = db))
    record <- abi_list("conspkg")
    expect_equal(record$exports$key, "conspkg::Derived")
    expect_equal(record$imports$key, "provpkg::Base")
  })
})

test_that("copies of classes of other packages are imported", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_pkg(root, "provpkg", "1.0",
                       code = c('setClassUnion("Base_OR_NULL", c("NULL", "logical"))', 'helper <- function(x) x'),
                       namespace = c("import(methods)", "exportClasses(Base_OR_NULL)", "export(helper)")), lib)
  # Redefining the union of provpkg (loaded at install time) stores a copy of
  # it in conspkg, with "character" added as a member
  install_pkg(make_pkg(root, "conspkg", "1.0",
                       code = c('setClass("Derived", representation(y = "character"))',
                                'setClassUnion("Base_OR_NULL", c("NULL", "character"))'),
                       namespace = c("import(methods)", "importFrom(provpkg, helper)", "exportClasses(Derived)"),
                       imports = "provpkg"), lib)
  with_lib(lib, {
    db <- abitools:::load_rdb(find.package("conspkg"), "conspkg")
    expect_equal(get(".__C__Base_OR_NULL", envir = db)@package, "provpkg")
    record <- abi_list("conspkg")
    expect_equal(record$exports$key, "conspkg::Derived")
    expect_equal(record$imports, abi_list("provpkg")$exports)
    expect_equal(abi_deps("conspkg")$detail, "Base_OR_NULL")
  })
})

test_that("superclasses of classes defined for another package are imported", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_provider(root, "1.0"), lib)
  # Like scde, which defines classes with package = "flexmix"
  install_pkg(make_pkg(root, "conspkg", "1.0",
                       code = 'setClass("Derived", contains = "Base", package = "provpkg")',
                       namespace = c("import(methods)", "importClassesFrom(provpkg, Base)"),
                       imports = "provpkg"), lib)
  with_lib(lib, {
    record <- abi_list("conspkg")
    expect_equal(nrow(record$exports), 0)
    expect_equal(record$imports$key, "provpkg::Base")
  })
})

test_that("the class hash covers the fields of reference classes", {
  env <- new.env()
  setRefClass("RefBase", fields = list(x = "numeric"), where = env)
  setRefClass("RefDerived", contains = "RefBase", fields = list(y = "character"), where = env)
  before <- abitools:::class_hash(getClass("RefDerived", where = env))
  # A new field in the superclass is cached in the subclass
  setRefClass("RefBase", fields = list(x = "numeric", z = "logical"), where = env)
  setRefClass("RefDerived", contains = "RefBase", fields = list(y = "character"), where = env)
  expect_false(identical(before, abitools:::class_hash(getClass("RefDerived", where = env))))
})

test_that("class unions of basic classes from loaded packages are ignored", {
  skip_on_cran()
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_pkg(root, "provpkg", "1.0",
                       code = c('setClassUnion("NULL_OR_list", c("NULL", "list"))', 'helper <- function(x) x'),
                       namespace = c("import(methods)", "exportClasses(NULL_OR_list)", "export(helper)")), lib)
  code <- 'setClass("Derived", contains = "list", representation(y = "character"))'
  # provpkg is loaded when conspkg is installed, so Derived gets NULL_OR_list as superclass
  install_pkg(make_pkg(root, "conspkg", "1.0", code = code,
                       namespace = c("import(methods)", "importFrom(provpkg, helper)", "exportClasses(Derived)"),
                       imports = "provpkg"), lib)
  install_pkg(make_pkg(root, "cprovpkg", "1.0", code = code,
                       namespace = c("import(methods)", "exportClasses(Derived)")), lib)
  with_lib(lib, {
    db <- abitools:::load_rdb(find.package("conspkg"), "conspkg")
    expect_true("NULL_OR_list" %in% names(get(".__C__Derived", envir = db)@contains))
    record <- abi_list("conspkg")
    expect_equal(nrow(record$imports), 0)
    expect_equal(record$exports$hash, abi_list("cprovpkg")$exports$hash)
    expect_equal(nrow(stale_classes("conspkg")), 0)
  })
})
