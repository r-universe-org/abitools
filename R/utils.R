base_packages <- c("base", "compiler", "datasets", "graphics", "grDevices", "grid",
  "methods", "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils")

# The first 16 hex digits (64 bits) of the SHA-256 of the lines: more than
# enough to detect changes (this is not used for security)
hash_text <- function(x){
  substr(unname(tools::sha256sum(bytes = charToRaw(paste(x, collapse = "\n")))), 1, 16)
}

read_description <- function(path){
  as.list(read.dcf(file.path(path, "DESCRIPTION"))[1, ])
}

parse_deps <- function(x){
  if (!length(x) || is.na(x))
    return(character())
  deps <- trimws(sub("\\(.*", "", strsplit(x, ",")[[1]]))
  setdiff(deps[nzchar(deps)], c("R", base_packages))
}

# Objects in the lazyload databases of an installed package. These hold the
# state at install time. Unserializing may load the namespaces they refer to.
load_rdb <- function(path, pkg){
  db <- new.env(parent = emptyenv())
  for (file in file.path(path, "R", c(pkg, "sysdata"))) {
    if (file.exists(paste0(file, ".rdb")))
      suppressMessages(lazyLoad(file, envir = db))
  }
  db
}

# The lazyload db also has copies of classes of other packages, e.g. a class
# union of S4Vectors that a class of the package was added to. Set
# copies = TRUE to get those instead of the classes of the package itself.
class_defs <- function(db, pkg, copies = FALSE){
  names <- grep("^\\.__C__", ls(db, all.names = TRUE), value = TRUE)
  defs <- lapply(names, get, envir = db)
  names(defs) <- sub("^\\.__C__", "", names)
  Filter(function(def) identical(def@package, pkg) != copies, defs)
}

super_package <- function(ext){
  attr(ext@superClass, "package") %||% ""
}

# Shared libraries of a package, but not the debug info that macOS stores in
# libs/pkg.so.dSYM/Contents/Resources/DWARF/pkg.so
shared_objects <- function(path){
  files <- list.files(file.path(path, "libs"), pattern = "\\.(so|dll|dylib)$",
                      recursive = TRUE, full.names = TRUE)
  files[!grepl(".dSYM/", files, fixed = TRUE)]
}

# Shared libraries that a package ships for others to link against, such as
# the TBB library in RcppParallel.
shipped_libraries <- function(path){
  list.files(file.path(path, "lib"), pattern = "\\.(so|dylib|dll)(\\.[0-9.]+)?$", recursive = TRUE)
}
