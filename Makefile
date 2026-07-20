EMACS ?= emacs
# Directory containing forge, ghub and their dependencies
# (layout as used by borg; override for other setups).
ELIB  ?= $(HOME)/.emacs.d/lib

LOAD_PATH = -L . \
  -L $(ELIB)/forge/lisp -L $(ELIB)/ghub/lisp -L $(ELIB)/closql \
  -L $(ELIB)/emacsql -L $(ELIB)/compat -L $(ELIB)/cond-let -L $(ELIB)/llama \
  -L $(ELIB)/magit/lisp -L $(ELIB)/transient/lisp -L $(ELIB)/with-editor/lisp \
  -L $(ELIB)/treepy -L $(ELIB)/yaml -L $(ELIB)/markdown-mode -L $(ELIB)/dash

.PHONY: all lisp test clean

all: lisp

lisp:
	$(EMACS) -Q --batch $(LOAD_PATH) -f batch-byte-compile forge-azure.el

test:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  -l forge-azure.el -l test/forge-azure-tests.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
