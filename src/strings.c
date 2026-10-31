/* Strings in a binary, see R/strings.R */
#include <Rinternals.h>
#include <stdio.h>

static int is_name_char(int c){
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
    c == '_' || c == '.';
}

/* Runs of 2 to 128 name characters that are followed by a NUL byte: the
 * C strings (such as function and package names) and symbols in a binary. The
 * result may contain duplicates. */
SEXP abitools_strings(SEXP file){
  FILE *f = fopen(CHAR(STRING_ELT(file, 0)), "rb");
  if (!f) Rf_error("Cannot open %s", CHAR(STRING_ELT(file, 0)));
  SEXP out = PROTECT(Rf_allocVector(STRSXP, 1024));
  R_xlen_t n = 0;
  char word[129];
  size_t len = 0;
  unsigned char buf[1 << 16];
  size_t got;
  while ((got = fread(buf, 1, sizeof buf, f)) > 0) {
    for (size_t i = 0; i < got; i++) {
      int c = buf[i];
      if (is_name_char(c)) {
        if (len < sizeof word) word[len] = (char) c;
        len++;
      } else {
        if (c == 0 && len >= 2 && len <= 128) {
          if (n == Rf_xlength(out)) {
            out = Rf_lengthgets(out, 2 * n);
            UNPROTECT(1);
            PROTECT(out);
          }
          SET_STRING_ELT(out, n++, Rf_mkCharLen(word, (int) len));
        }
        len = 0;
      }
    }
  }
  fclose(f);
  out = Rf_lengthgets(out, n);
  UNPROTECT(1);
  return out;
}
