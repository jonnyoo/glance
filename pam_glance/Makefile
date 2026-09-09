# Builds pam_glance.so for Face-for-sudo.
# Do NOT place the .so under glance/Resources in the source tree — Xcode's
# synchronized group would link it and crash launch. The Xcode build phase
# "Embed pam_glance" (or `make embed APP=...`) copies it into the built app.
#
# Usage:
#   make -C pam_glance
#   make -C pam_glance embed APP=/path/to/glance.app

MODULE = pam_glance.so
SRC = pam_glance.c

CFLAGS ?= -Wall -Wextra -O2 -fPIC
LDFLAGS ?= -dynamiclib -lpam

.PHONY: all clean embed

all: $(MODULE)

$(MODULE): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

# Manual embed into an already-built .app (CI / packaging).
embed: $(MODULE)
	@test -n "$(APP)" || (echo "usage: make -C pam_glance embed APP=/path/to/glance.app" >&2; exit 1)
	./embed-resources.sh "$(APP)/Contents/Resources"

clean:
	rm -f $(MODULE)
