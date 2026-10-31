# Hashes of the C functions that a package registers with R_RegisterCCallable().
# The hash covers the signature of the function as described by libclang (see
# clang.R and SPEC.md). Functions that are not found in the headers are not
# exported: a dependent cannot have been compiled against their declaration.
c_function_hashes <- function(pkg, path, lib.loc = NULL, flags = NULL){
  names <- registered_callables(pkg, path, lib.loc)
  if (!length(names))
    return(character())
  sigs <- clang_signatures(pkg, path, names, lib.loc, flags)
  found <- !is.na(sigs)
  hashes <- vapply(sigs[found], hash_text, "", USE.NAMES = FALSE)
  names(hashes) <- paste0(pkg, "::", names[found], "()")
  hashes
}

# There is no list of registered functions, so try the identifiers that are
# stored as strings in the shared library of the package, and that are also
# found in its headers (possibly with a prefix, see callable_variants()).
# Trying a name that is not registered is slow, so the headers narrow it down.
#' @useDynLib abitools, .registration = TRUE
registered_callables <- function(pkg, path, lib.loc = NULL){
  libs <- shared_objects(path)
  if (!length(libs) || !registers_callables(libs))
    return(character())
  words <- header_words(path)
  if (!length(words))
    return(character())
  loaded <- tryCatch(loadNamespace(pkg, lib.loc = lib.loc), error = function(e) NULL)
  if (is.null(loaded))
    return(character())
  words <- c(words, paste0("_", words), paste0("_", pkg, "_", words), sub("^_?[A-Za-z0-9]+_", "", words))
  candidates <- intersect(binary_strings(libs), words)
  ok <- vapply(candidates, function(name){
    isTRUE(tryCatch(.Call(abitools_ccallable, pkg, name), error = function(e) FALSE))
  }, logical(1))
  sort(candidates[ok], method = "radix")
}

# All identifiers in the headers of a package, also in comments and strings
header_words <- function(path){
  files <- list.files(file.path(path, "include"), recursive = TRUE, full.names = TRUE)
  unique(unlist(lapply(files, function(file){
    text <- readLines(file, warn = FALSE)
    regmatches(text, gregexpr("[A-Za-z_][A-Za-z0-9_]*", text, useBytes = TRUE))
  })))
}
