test_that("strings in a binary are runs of name characters followed by NUL", {
  file <- tempfile()
  on.exit(unlink(file))
  nul <- as.raw(0)
  writeBin(c(
    nul, charToRaw("Rsamtools"), nul,
    # The first string of a section may directly follow machine code
    as.raw(c(0xc0, 0x03, 0x5f, 0xd6)), charToRaw("prov_add"), nul,
    # Not followed by NUL, or too short
    charToRaw("partial"), as.raw(0x80), charToRaw("x"), nul,
    # Linkers merge "IRanges" into the tail of "_new_IRanges"
    nul, charToRaw("_new_IRanges"), nul,
    # Linked libraries are referenced by path, e.g. @rpath/libtbb.dylib
    charToRaw("@rpath/libtbb.dylib"), nul, charToRaw("libtbb.so.2"), nul
  ), file)
  strings <- abitools:::binary_strings(file)
  expect_setequal(strings, c("Rsamtools", "prov_add", "_new_IRanges", "libtbb.dylib", "libtbb.so.2"))
  # Package names of C APIs match as the tail of a string, function names exactly
  expect_true(any(endsWith(strings, "IRanges")))
  expect_false("IRanges" %in% strings)
  expect_false(any(endsWith(strings, "Ranges_")))
})

test_that("strings longer than 128 bytes are skipped, also across buffer boundaries", {
  file <- tempfile()
  on.exit(unlink(file))
  long <- paste(rep("a", 129), collapse = "")
  bytes <- c(charToRaw(long), as.raw(0), charToRaw("ok"), as.raw(0))
  writeBin(c(raw(65536 - 10), bytes), file)
  expect_equal(abitools:::binary_strings(file), "ok")
})

test_that("packages without a shared library have no strings", {
  # A LinkingTo dependency can be header-only, such as cpp11 or BH
  expect_equal(abitools:::binary_strings(character()), character())
  expect_false(abitools:::registers_callables(character()))
})
