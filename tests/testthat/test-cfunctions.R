test_that("only changes in the C functions that a package calls require a rebuild", {
  root <- tempfile()
  lib <- file.path(root, "lib")
  dir.create(lib, recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE))

  install_pkg(make_c_provider(root, "1.0"), lib)
  install_pkg(make_c_consumer(root), lib)
  record <- with_lib(lib, {
    expect_equal(abi_deps("cconspkg")$type, "C API")
    exports <- abi_list("cprovpkg")$exports
    # prov_hidden() is registered, but not in the header, so it is not exported
    expect_equal(exports$key, c("cprovpkg/include", "cprovpkg::prov_add()", "cprovpkg::prov_info()"))
    x <- abi_list("cconspkg")
    expect_equal(x$imports$key, "cprovpkg::prov_add()")
    expect_equal(nrow(abi_check(x)), 0)
    list(record = x, exports = exports)
  })

  # A new function, and a changed struct that prov_add() does not use
  install_pkg(make_c_provider(root, "1.1", struct = "int a; double b;", extra = "int prov_new(void);"), lib)
  with_lib(lib, {
    exports <- abi_list("cprovpkg")$exports
    changed <- exports$key[!exports$hash %in% record$exports$hash]
    expect_equal(changed, c("cprovpkg/include", "cprovpkg::prov_info()"))
    expect_equal(nrow(abi_check(record$record)), 0)
  })

  # Renamed parameters of prov_add()
  install_pkg(make_c_provider(root, "1.2", add_args = "int a, int b"), lib)
  with_lib(lib, {
    expect_equal(nrow(abi_check(record$record)), 0)
  })

  # A changed signature of prov_add()
  install_pkg(make_c_provider(root, "1.3", add_args = "int x, double y"), lib)
  with_lib(lib, {
    expect_equal(abi_check(record$record)$reason, "C function prov_add() changed")
  })
})
