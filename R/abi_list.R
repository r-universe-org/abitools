#' ABI imports and exports of a package
#'
#' Lists the parts of the binary interface of an installed package that matter
#' for deciding when packages need to be rebuilt. Run this right after a
#' package was built, in the library that it was built with.
#'
#' The **exports** are the parts of the package that dependents may copy at
#' build time: a hash of each S4 class definition, a hash of the C headers in
#' its `include` directory, and a hash of each C function that it registers
#' with `R_RegisterCCallable()`. The hash of a C function covers its
#' declaration in the headers, and the definitions of the types that it uses.
#' Unlike the version, these hashes only change when something changes that
#' affects dependents.
#'
#' The **imports** are the exports of its dependencies that the package copied
#' when it was built: the classes that it extends, the C functions of `C API`
#' dependencies that it calls, and the headers of `linked library`
#' dependencies (see [abi_deps()]). Other classes and functions of the
#' dependency are not included, so a change in those does not trigger a
#' rebuild.
#'
#' A package needs to be rebuilt when one of its imports no longer matches the
#' current export of the dependency, see [abi_check()]. Code that was copied
#' from a dependency (such as `f <- dep:::g`) has no hash, and is left to
#' periodic rebuilds.
#'
#' The data frames are flat, so that [jsonlite::toJSON()] gives lists of
#' entries that are easy to store and query in a database.
#'
#' @inheritParams abi_deps
#' @return a list with data frames `exports` and `imports`, both with columns
#' `key` and `hash`. The key is `<package>::<class>` for an S4 class,
#' `<package>::<function>()` for a C function, or `<package>/include` for the
#' C headers. Package names cannot contain `:` or `/`, so the package is
#' everything before the first `::` or `/`.
#' @export
#' @examples
#' abi_list("stats4")
abi_list <- function(pkg, lib.loc = NULL){
  list(exports = abi_exports(pkg, lib.loc), imports = abi_imports(pkg, lib.loc))
}

abi_exports <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  defs <- class_defs(load_rdb(path, pkg), pkg)
  headers <- header_hash(path)
  functions <- c_function_hashes(pkg, path, lib.loc)
  abi_table(
    key = c(if (length(headers)) paste0(pkg, "/include"), if (length(defs)) paste0(pkg, "::", names(defs)), names(functions)),
    hash = c(headers, vapply(defs, class_hash, "", USE.NAMES = FALSE), unname(functions))
  )
}

abi_imports <- function(pkg, lib.loc = NULL){
  path <- find.package(pkg, lib.loc)
  deps <- rbind(linkingto_deps(path, lib.loc), s4_deps(load_rdb(path, pkg), pkg, lib.loc))
  deps <- deps[deps$type != "headers", ]
  strings <- NULL
  out <- abi_table()
  for (dep in unique(deps$package)) {
    rows <- deps[deps$package == dep, ]
    exports <- abi_exports(dep, lib.loc)
    wanted <- paste0(dep, "::", rows$detail[rows$type == "S4 class"])
    if ("C API" %in% rows$type) {
      # The C functions of the dependency that the package calls by name
      strings <- strings %||% binary_strings(shared_objects(path))
      functions <- grep("\\(\\)$", exports$key, value = TRUE)
      used <- functions[sub("^[^:]*::(.*)\\(\\)$", "\\1", functions) %in% strings]
      wanted <- c(wanted, used)
    }
    if ("linked library" %in% rows$type)
      wanted <- c(wanted, paste0(dep, "/include"))
    out <- rbind(out, exports[exports$key %in% wanted, ])
  }
  abi_table(out$key, out$hash)
}

abi_table <- function(key = character(), hash = character()){
  out <- data.frame(key = c(character(), key), hash = c(character(), hash))
  out <- out[order(out$key, method = "radix"), ]
  row.names(out) <- NULL
  out
}

# Package names cannot contain ':' or '/'
key_package <- function(key){
  sub("(::|/).*$", "", key)
}

# The slots and fields include the inherited ones, so a change in any of the
# superclasses also changes the hash of the class.
class_hash <- function(def){
  slots <- def@slots
  slots <- sprintf("slot %s: %s@%s", names(slots), slots,
                   vapply(slots, function(s) attr(s, "package") %||% "", ""))
  fields <- if (methods::is(def, "refClassRepresentation")) def@fieldClasses
  fields <- sprintf("field %s: %s", names(fields), fields)
  supers <- vapply(def@contains, function(ext){
    sprintf("contains %s@%s", ext@superClass, super_package(ext))
  }, "")
  hash_text(c(def@className, paste("virtual:", def@virtual), sort(slots, method = "radix"),
              sort(fields, method = "radix"), sort(supers, method = "radix")))
}

header_hash <- function(path){
  inc <- file.path(path, "include")
  files <- sort(list.files(inc, recursive = TRUE), method = "radix")
  if (!length(files))
    return(NULL)
  hash_text(paste(files, tools::sha256sum(file.path(inc, files))))
}
