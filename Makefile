one:
	echo $(GLOBAL_VAR)

prog : *.c

foo : prog
	echo "prog is updated"
