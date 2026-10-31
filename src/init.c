#include <Rinternals.h>
#include <R_ext/Rdynload.h>

/* R_GetCCallable() raises an error if the function is not registered */
SEXP abitools_ccallable(SEXP pkg, SEXP name){
  DL_FUNC fun = R_GetCCallable(CHAR(STRING_ELT(pkg, 0)), CHAR(STRING_ELT(name, 0)));
  return Rf_ScalarLogical(fun != NULL);
}

SEXP abitools_strings(SEXP);
SEXP abitools_clang_resource_dir(void);
SEXP abitools_clang_signatures(SEXP, SEXP, SEXP, SEXP, SEXP);

static const R_CallMethodDef CallEntries[] = {
  {"abitools_ccallable", (DL_FUNC) &abitools_ccallable, 2},
  {"abitools_strings", (DL_FUNC) &abitools_strings, 1},
  {"abitools_clang_resource_dir", (DL_FUNC) &abitools_clang_resource_dir, 0},
  {"abitools_clang_signatures", (DL_FUNC) &abitools_clang_signatures, 5},
  {NULL, NULL, 0}
};

void R_init_abitools(DllInfo *dll){
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
