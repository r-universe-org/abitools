# Signatures of C functions with libclang (see SPEC.md). This runs the
# preprocessor and describes the actual ABI: the canonical types of the return
# value and the parameters, and for structs that are defined in the headers of
# the package (or its LinkingTo dependencies) their size, alignment and field
# offsets.

clang_resource_dir <- function(){
  .Call(abitools_clang_resource_dir)
}

# Returns the signature of each of the registered functions of a package, or
# NA for the functions that were not found.
clang_signatures <- function(pkg, path, names, lib.loc = NULL, flags = NULL){
  out <- rep(NA_character_, length(names))
  names(out) <- names
  if (!length(names))
    return(out)
  variants <- lapply(names, callable_variants, pkg = pkg)
  config <- clang_config(path, lib.loc, flags)
  for (file in entry_headers(config$own, unique(unlist(variants)))) {
    res <- clang_parse(file.path(config$own, file), unique(unlist(variants)), config)
    if (is.null(res))
      next
    # Per function, use the first header (that parses without errors) that has it
    for (i in which(is.na(out))) {
      out[i] <- pick_signature(res, variants[[i]])
    }
    if (!anyNA(out))
      break
  }
  out
}

# Prefer the cast at a call site of R_GetCCallable("pkg", "name"): this is the
# type that dependents actually use to call the function. Then a declaration
# of the registered name (or the name without the prefix that stub macros
# add), and then a declaration with a prefix (M_ in Matrix). Declarations are
# less reliable in C++, where other namespaces may have functions with the
# same name.
pick_signature <- function(res, variants){
  for (kind in c("callsite", "declaration", "prefix")) {
    for (name in variants) {
      sig <- res$sig[res$kind == kind & res$name == name]
      if (length(sig))
        return(paste(sort(unique(sig), method = "radix"), collapse = "\n"))
    }
  }
  NA_character_
}

callable_variants <- function(name, pkg){
  unique(c(name, sub(paste0("^_", pkg, "_"), "", name), sub("^_", "", name)))
}

# Parse a header as C, or as C++ if that gives errors. Clang keeps going after
# an error (such as a missing include), and the declarations that are affected
# by it are marked invalid and not used (see clang.c). The parse with the
# fewest errors is used, and if equal, the one that found more signatures (a
# C++ header parsed as C finds none). Set options(abitools.verbose = TRUE) to
# see the errors.
clang_parse <- function(file, names, config){
  cpp_only <- grepl("\\.(hpp|hh|cc|cpp)$|/[^./]+$", file)
  best <- NULL
  for (lang in if (cpp_only) "c++" else c("c", "c++")) {
    std <- if (lang == "c++") c("-std=gnu++17", "-DR_NO_REMAP") else "-std=gnu17"
    args <- c("-x", lang, std, config$args)
    res <- .Call(abitools_clang_signatures, file, args, names, config$own, config$dirs)
    if (is.null(res))
      next
    if (res$errors == 0)
      return(data.frame(name = res$name, kind = res$kind, sig = res$sig))
    if (isTRUE(getOption("abitools.verbose")))
      message(sprintf("%d errors parsing %s as %s:\n%s", res$errors, file, lang, paste(res$messages, collapse = "\n")))
    if (is.null(best) || res$errors < best$errors ||
        (res$errors == best$errors && length(res$name) > length(best$name)))
      best <- res
  }
  if (!is.null(best))
    data.frame(name = best$name, kind = best$kind, sig = best$sig)
}

# Compiler arguments as for a package that links to this one: the include
# directories of R, the package, and its own LinkingTo dependencies, and the
# extra flags (e.g. for system libraries). Headers of R packages expect that
# the R headers were included before.
clang_config <- function(path, lib.loc = NULL, flags = NULL){
  desc <- file.path(path, "DESCRIPTION")
  linkingto <- if (file.exists(desc)) parse_deps(read_description(path)$LinkingTo) else character()
  dirs <- file.path(c(path, find.package(linkingto, lib.loc, quiet = TRUE)), "include")
  dirs <- normalizePath(dirs[dir.exists(dirs)])
  args <- c("-resource-dir", clang_resource_dir(), paste0("-I", R.home("include")),
            paste0("-I", dirs), flags, "-w", "-include", "Rinternals.h", "-include", "R_ext/Rdynload.h")
  if (Sys.info()[["sysname"]] == "Darwin") {
    sdk <- tryCatch(system2("xcrun", "--show-sdk-path", stdout = TRUE, stderr = FALSE), error = function(e) NULL)
    if (length(sdk))
      args <- c(args, "-isysroot", sdk)
  }
  list(args = args, dirs = dirs, own = normalizePath(file.path(path, "include")))
}

# The headers to parse: the files at the top of the include directory (or
# one level down if there are none), and other files that mention the names
entry_headers <- function(inc, names){
  files <- list.files(inc, recursive = TRUE)
  files <- files[grepl("\\.(h|hpp|hh|c|cc|cpp)$|^[^.]+$", basename(files))]
  if (!length(files))
    return(character())
  depth <- lengths(regmatches(files, gregexpr("/", files)))
  top <- files[depth == min(depth)]
  mentions <- files[vapply(file.path(inc, files), function(file){
    text <- paste(readLines(file, warn = FALSE), collapse = "\n")
    any(vapply(names, grepl, logical(1), x = text, fixed = TRUE))
  }, logical(1))]
  unique(c(sort(top, method = "radix"), sort(mentions, method = "radix")))
}
