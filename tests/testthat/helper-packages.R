# Create and install small test packages in a temporary library
make_pkg <- function(root, name, version, code, namespace, imports = NULL,
                     linkingto = NULL, header = NULL, src = NULL){
  dir <- file.path(root, name)
  unlink(dir, recursive = TRUE)
  dir.create(file.path(dir, "R"), recursive = TRUE)
  desc <- c(Package = name, Version = version, Title = "Test Package",
            Description = "Test package.", License = "MIT",
            Author = "Test", Maintainer = "Test <test@example.com>",
            Imports = paste(c("methods", imports), collapse = ", "))
  if (length(linkingto))
    desc["LinkingTo"] <- linkingto
  write.dcf(t(desc), file.path(dir, "DESCRIPTION"))
  writeLines(code, file.path(dir, "R", "code.R"))
  writeLines(namespace, file.path(dir, "NAMESPACE"))
  if (length(header)) {
    dir.create(file.path(dir, "inst", "include"), recursive = TRUE)
    writeLines(header, file.path(dir, "inst", "include", paste0(name, ".h")))
  }
  if (length(src)) {
    dir.create(file.path(dir, "src"))
    writeLines(src, file.path(dir, "src", paste0(name, ".c")))
    writeLines("PKG_CPPFLAGS = -I../inst/include", file.path(dir, "src", "Makevars"))
  }
  dir
}

install_pkg <- function(dir, lib){
  for (pkg in c("cconspkg", "conspkg", "cprovpkg", "provpkg")) {
    if (isNamespaceLoaded(pkg)) unloadNamespace(pkg)
    dll <- getLoadedDLLs()[[pkg]]
    if (!is.null(dll)) dyn.unload(dll[["path"]])
  }
  status <- system2(file.path(R.home("bin"), "R"),
    c("CMD", "INSTALL", "--no-test-load", paste0("--library=", shQuote(lib)), shQuote(dir)),
    env = paste0("R_LIBS=", shQuote(lib)), stdout = FALSE, stderr = FALSE)
  stopifnot(status == 0)
}

make_provider <- function(root, version, slots = 'representation(x = "numeric")', header = "#define PROV 1"){
  make_pkg(root, "provpkg", version,
    code = c(sprintf('setClass("Base", %s)', slots),
             'setClass("Other", representation(a = "logical"))',
             'helper <- function(x) x + 1'),
    namespace = c("import(methods)", "exportClasses(Base, Other)", "export(helper)"),
    header = header)
}

make_consumer <- function(root){
  make_pkg(root, "conspkg", "1.0",
    code = c('setClass("Derived", contains = "Base", representation(y = "character"))',
             'plus_one <- provpkg::helper'),
    namespace = c("import(methods)", "importClassesFrom(provpkg, Base)",
                  "exportClasses(Derived)", "export(plus_one)"),
    imports = "provpkg", linkingto = "provpkg")
}

# A package with a C API: prov_add() and prov_info() are registered
make_c_provider <- function(root, version, add_args = "int x, int y", struct = "int a;", extra = NULL){
  header <- c("/* prov_hidden() is registered, but not declared here */",
              "typedef struct prov_struct {", struct, "} prov_t;",
              sprintf("int prov_add(%s);", add_args),
              "int prov_info(prov_t *p);", extra)
  src <- c("#include <Rinternals.h>", "#include <R_ext/Rdynload.h>", "#include <cprovpkg.h>",
           sprintf("int prov_add(%s){ return 0; }", add_args),
           "int prov_info(prov_t *p){ return 0; }",
           "/* Registered, but not declared in the header */",
           "static int prov_hidden(void){ return 0; }",
           "void R_init_cprovpkg(DllInfo *dll){",
           '  R_RegisterCCallable("cprovpkg", "prov_hidden", (DL_FUNC) &prov_hidden);',
           '  R_RegisterCCallable("cprovpkg", "prov_add", (DL_FUNC) &prov_add);',
           '  R_RegisterCCallable("cprovpkg", "prov_info", (DL_FUNC) &prov_info);',
           "}")
  make_pkg(root, "cprovpkg", version, code = "f <- function() NULL",
           namespace = c("useDynLib(cprovpkg)", "export(f)"), header = header, src = src)
}

# Calls prov_add() from the C API of cprovpkg
make_c_consumer <- function(root){
  src <- c("#include <Rinternals.h>", "#include <R_ext/Rdynload.h>",
           "SEXP cons_add(SEXP x, SEXP y){",
           "  static int (*fun)(int, int) = NULL;",
           '  if (fun == NULL) fun = (int (*)(int, int)) R_GetCCallable("cprovpkg", "prov_add");',
           "  return ScalarInteger(fun(asInteger(x), asInteger(y)));",
           "}")
  make_pkg(root, "cconspkg", "1.0", code = 'add <- function(x, y) .Call("cons_add", x, y, PACKAGE = "cconspkg")',
           namespace = c("useDynLib(cconspkg)", "importFrom(cprovpkg, f)"),
           imports = "cprovpkg", linkingto = "cprovpkg", src = src)
}

with_lib <- function(lib, code){
  old <- .libPaths()
  on.exit(.libPaths(old))
  .libPaths(c(lib, old))
  force(code)
}
