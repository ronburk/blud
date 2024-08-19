one:
	echo $(GLOBAL_VAR)

prog : blud.o

foo : prog
	echo "prog is updated"
