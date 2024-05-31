# test makefile
FOO:=$$
GLOBAL_VAR = $(FOO)x
FEE=$(GLOBAL_VAR)

all: private GLOBAL_VAR = y
all: one
	echo $(FOO)$(FEE)
	echo $(GLOBAL_VAR)

one:
	echo $(GLOBAL_VAR)
