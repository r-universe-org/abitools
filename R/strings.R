# Strings in the shared libraries of a package: runs of name characters
# [A-Za-z0-9_.] that are followed by a NUL byte (see src/strings.c). These are
# the string literals of the code (such as the names that are passed to
# R_GetCCallable()) and the symbol names of the binary. A string usually also
# starts after a NUL, but not if it is the first one of a section, or if the
# linker merged it into the tail of a longer string ("IRanges" into
# "_new_IRanges"). So look for an exact match when a false match would be
# harmful (the names of C functions), and for a suffix otherwise.
#
# Cached, because a package is inspected both as a dependency and as a
# dependent.
strings_cache <- new.env(parent = emptyenv())

binary_strings <- function(files){
  unique(as.character(unlist(lapply(files, function(file){
    info <- file.info(file)
    id <- paste(normalizePath(file), info$size, as.numeric(info$mtime))
    strings_cache[[id]] <- strings_cache[[id]] %||% unique(.Call(abitools_strings, file))
  }))))
}

# Whether a package registers C functions with R_RegisterCCallable(). The
# symbol is stored as _R_RegisterCCallable on macOS.
registers_callables <- function(libs){
  any(endsWith(binary_strings(libs), "R_RegisterCCallable"))
}
