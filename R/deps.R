#' Critical dependencies of an installed package
#'
#' Finds the dependencies of which the installed package holds a copy, or
#' whose binary interface it was compiled against. When one of these changes,
#' the package may need to be rebuilt.
#'
#' The `type` column in the result is one of:
#'
#'  - `C API`: a `LinkingTo` dependency that registers C functions with
#'    `R_RegisterCCallable()`, which the shared library of the package calls at
#'    runtime via `R_GetCCallable()`. Changes in its headers (struct layouts,
#'    function signatures) break the binary.
#'  - `linked library`: a `LinkingTo` dependency that ships a shared library
#'    in its `lib` directory (such as TBB in RcppParallel), which the shared
#'    library of the package links to.
#'  - `headers`: a `LinkingTo` dependency that is not called at runtime, for
#'    example a header-only or static library. The binary keeps working when
#'    it changes, so this is informational only.
#'  - `S4 class`: an S4 or reference class in the package extends this class
#'    from the dependency. The definition of the subclass, including the
#'    inherited slots, was copied at install time.
#'  - `copied code`: objects in the package (such as `f <- dep:::g`) contain
#'    functions or environments of the dependency.
#'
#' The package is inspected without loading it, but namespaces referenced by
#' its lazyload database are loaded. Call this in the library that was used to
#' build the package.
#'
#' @param pkg name of an installed package
#' @param lib.loc library to search, defaults to [.libPaths()]
#' @param ignore namespaces whose code is copied by design, such as the
#' generator functions of R6 classes.
#' @return a data frame with columns `package`, `type` and `detail`
#' @export
#' @examples
#' abi_deps("stats4")
abi_deps <- function(pkg, lib.loc = NULL, ignore = "R6"){
  path <- find.package(pkg, lib.loc)
  db <- load_rdb(path, pkg)
  copied <- copied_code(db, pkg, ignore)
  out <- rbind(
    linkingto_deps(path, lib.loc),
    s4_deps(db, pkg, lib.loc),
    deps_table(names(copied) %||% character(), "copied code", unname(vapply(copied, paste, "", collapse = ", ")))
  )
  out <- unique(out)
  out <- out[order(out$package, out$type, out$detail, method = "radix"), ]
  row.names(out) <- NULL
  out
}

deps_table <- function(package = character(), type = character(), detail = character()){
  data.frame(package = package, type = rep(type, length.out = length(package)),
             detail = rep(detail, length.out = length(package)))
}

linkingto_deps <- function(path, lib.loc = NULL){
  libs <- shared_objects(path)
  deps <- parse_deps(read_description(path)$LinkingTo)
  types <- vapply(deps, linkingto_type, "", libs = libs, lib.loc = lib.loc)
  deps_table(deps, unname(types), "")
}

linkingto_type <- function(dep, libs, lib.loc){
  dep_path <- tryCatch(find.package(dep, lib.loc), error = function(e) NULL)
  if (length(libs) && length(dep_path)) {
    strings <- binary_strings(libs)
    # A C API is registered with R_RegisterCCallable() and called through
    # R_GetCCallable("pkg", "fun"), so the caller contains the package name
    if (registers_callables(shared_objects(dep_path)) && any(endsWith(strings, dep)))
      return("C API")
    # A linked library is referenced by file name, e.g. @rpath/libtbb.dylib
    if (any(basename(shipped_libraries(dep_path)) %in% strings))
      return("linked library")
  }
  "headers"
}

s4_deps <- function(db, pkg, lib.loc){
  out <- deps_table()
  copies <- class_defs(db, pkg, copies = TRUE)
  # Copies include classes that a package defines with the 'package' argument
  # of setClass() set to another package (scde does this for flexmix)
  for (def in c(class_defs(db, pkg), copies)) {
    for (ext in def@contains) {
      dep <- super_package(ext)
      if (dep %in% c(pkg, base_packages, "", ".GlobalEnv"))
        next
      out <- rbind(out, s4_dep(dep, as.character(ext@superClass), lib.loc))
    }
  }
  # When loaded, these copies replace the definitions of the other package
  for (def in copies) {
    if (!def@package %in% c(base_packages, "", ".GlobalEnv"))
      out <- rbind(out, s4_dep(def@package, as.character(def@className), lib.loc))
  }
  unique(out)
}

s4_dep <- function(dep, class, lib.loc){
  provider <- provider_class(dep, class, lib.loc)
  if (length(provider) && !"oldClass" %in% names(provider@contains))
    deps_table(dep, "S4 class", class)
}

provider_class <- function(dep, class, lib.loc){
  path <- tryCatch(find.package(dep, lib.loc), error = function(e) NULL)
  if (is.null(path))
    return(NULL)
  db <- load_rdb(path, dep)
  get0(paste0(".__C__", class), envir = db, inherits = FALSE)
}

# Walk all objects in the lazyload db and find closures or environments
# whose enclosure is the namespace of another package.
copied_code <- function(db, pkg, ignore = character()){
  skip <- "^\\.__(C|T)__|^\\.__NAMESPACE__\\.$|^\\.__S3MethodsTable__\\.$|^\\.packageName$|^\\.__rlang_hook__\\.$|^\\.S3MethodsClasses$"
  seen <- new.env(hash = TRUE, parent = emptyenv())
  hits <- list()
  walk <- function(x, name, depth = 0){
    if (depth > 30)
      return()
    if (methods::is(x, "genericFunction"))
      return() # method caches in generics are rebuilt when loaded
    if (is.function(x) && !is.primitive(x))
      return(walk(environment(x), name, depth + 1))
    if (is.environment(x)) {
      if (isNamespace(x)) {
        ns <- getNamespaceName(x)
        if (ns != pkg)
          hits[[ns]] <<- unique(c(hits[[ns]], name))
        return()
      }
      if (identical(x, globalenv()) || identical(x, baseenv()) || identical(x, emptyenv()))
        return()
      id <- format(x)
      if (exists(id, envir = seen, inherits = FALSE))
        return()
      assign(id, TRUE, envir = seen)
      for (nm in ls(x, all.names = TRUE)) {
        if (!bindingIsActive(nm, x))
          tryCatch(walk(get(nm, envir = x), name, depth + 1), error = function(e) NULL)
      }
      return(walk(parent.env(x), name, depth + 1))
    }
    if (is.list(x) || is.pairlist(x)) {
      for (el in x) walk(el, name, depth + 1)
    }
    if (isS4(x) && !is.function(x)) {
      for (sl in methods::slotNames(x)) walk(methods::slot(x, sl), name, depth + 1)
    }
    for (a in setdiff(names(attributes(x)), c("names", "class", "srcref", "row.names", "dim", "dimnames"))) {
      walk(attr(x, a), name, depth + 1)
    }
  }
  for (name in grep(skip, ls(db, all.names = TRUE), value = TRUE, invert = TRUE)) {
    tryCatch(walk(get(name, envir = db), name), error = function(e) NULL)
  }
  hits[setdiff(names(hits), c(base_packages, ignore))]
}
