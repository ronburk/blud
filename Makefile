all : myprog

foo : fee

fee :
	echo fee

myprog : cstr.o


prog : file.o


all: tool

# GENERATED PART START
main.o: src/main.c src/sub/file.h
sub/file.o: src/sub/file.c src/sub/file.h
# GENERATED PART END

# main.o : main.o: fee.obj

%.o: src/%.c
	mkdir -p $(dir $@)
	gcc -c -o $@ $<


OBJS = main.o sub/file.o

$(OBJS) : %.o: src/%.c
	mkdir -p $(@D)
	gcc -c -o $@ $<


tool: main.o sub/file.o 
	gcc -I src -o $@ $^

.PHONY: all
