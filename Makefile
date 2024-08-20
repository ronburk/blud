one:
	echo $(GLOBAL_VAR)

prog : *.c
	echo $(patsubst *.c,foo,abcd)

foo : prog
	echo "prog is updated"
