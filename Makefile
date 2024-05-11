# test makefile
GLOBAL_VAR = x

all: private GLOBAL_VAR = y
all: one
	echo $(GLOBAL_VAR)

one:
	echo $(GLOBAL_VAR)
