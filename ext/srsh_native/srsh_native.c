#include <ruby.h>
#include <string.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static VALUE ident_end(VALUE self, VALUE str, VALUE offv) {
    Check_Type(str, T_STRING);
    long off = NUM2LONG(offv);
    long len = RSTRING_LEN(str);
    const unsigned char *p = (const unsigned char *)RSTRING_PTR(str);
    if (off < 0 || off > len) rb_raise(rb_eArgError, "offset out of range");

    long i = off;
    while (i < len) {
        unsigned char c = p[i];
        if (!(c == '_' || (c >= 'a' && c <= 'z') ||
              (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) break;
        i++;
    }
    return LONG2NUM(i);
}

static VALUE ascii_space(VALUE self, VALUE chv) {
    int c = NUM2INT(chv);
    return (c == ' ' || c == '\t' || c == '\r' || c == '\n') ? Qtrue : Qfalse;
}

static VALUE set_process_name(VALUE self, VALUE namev) {
#ifdef __linux__
    const char *name = StringValueCStr(namev);
    char short_name[16];
    memset(short_name, 0, sizeof(short_name));
    strncpy(short_name, name, sizeof(short_name) - 1);
    return prctl(PR_SET_NAME, (unsigned long)short_name, 0, 0, 0) == 0 ? Qtrue : Qfalse;
#else
    (void)self;
    (void)namev;
    return Qfalse;
#endif
}

void Init_srsh_native(void) {
    VALUE m = rb_define_module("SrshNative");
    rb_define_singleton_method(m, "ident_end", ident_end, 2);
    rb_define_singleton_method(m, "ascii_space?", ascii_space, 1);
    rb_define_singleton_method(m, "set_process_name", set_process_name, 1);
}
