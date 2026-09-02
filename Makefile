RUBY ?= ruby
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBROOT ?= $(PREFIX)/lib
DLEXT := $(shell $(RUBY) -rrbconfig -e 'print RbConfig::CONFIG["DLEXT"]')
NATIVE := ext/srsh_native/srsh_native.$(DLEXT)

.DEFAULT_GOAL := test
.PHONY: test syntax examples smoke native clean install uninstall release-check

test:
	$(RUBY) -w -Ilib -Itest test/test_language.rb
	$(RUBY) -w -Ilib -Itest test/test_shell.rb

syntax:
	@find lib bin test -type f \( -name '*.rb' -o -path 'bin/srsh' \) -print0 | \
		xargs -0 -n1 $(RUBY) -c >/dev/null
	@echo "ruby syntax: ok"

examples:
	@set -e; for f in examples/*.rsh; do ./bin/srsh --norc --check "$$f" >/dev/null; done
	@echo "rsh examples: syntax ok"

smoke:
	./bin/srsh --norc examples/power.rsh >/dev/null
	./bin/srsh --norc examples/modules.rsh >/dev/null
	./bin/srsh --norc examples/bridge.rsh >/dev/null
	./bin/srsh --norc examples/defer.rsh >/dev/null
	@echo "examples: run ok"

native:
	cd ext/srsh_native && $(RUBY) extconf.rb && $(MAKE)

release-check: syntax test examples smoke native test
	@echo "srsh release check: ok"

clean:
	@if [ -f ext/srsh_native/Makefile ]; then $(MAKE) -C ext/srsh_native clean; fi
	rm -f ext/srsh_native/Makefile ext/srsh_native/mkmf.log ext/srsh_native/*.$(DLEXT) ext/srsh_native/*.o

install:
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBROOT)
	install -m 0755 bin/srsh $(DESTDIR)$(BINDIR)/srsh
	cp -R lib/srsh.rb lib/srsh $(DESTDIR)$(LIBROOT)/
	@if [ -f "$(NATIVE)" ]; then install -m 0755 "$(NATIVE)" "$(DESTDIR)$(LIBROOT)/srsh_native.$(DLEXT)"; fi

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/srsh
	rm -f $(DESTDIR)$(LIBROOT)/srsh.rb
	rm -rf $(DESTDIR)$(LIBROOT)/srsh
	rm -f $(DESTDIR)$(LIBROOT)/srsh_native.$(DLEXT)
