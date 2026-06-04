#LUAJIT_FLAGS="$(pkg-config --cflags --libs luajit)"
LUAJIT_FLAGS="$(pkg-config --cflags --libs luajit) -Wl,-rpath,/usr/local/lib"
#LDFLAGS="-L./luajit/src -lluajit"
CFLAGS="-Wall -Wextra -fmax-errors=2"
# build cstr utility
g++ -o cstr cstr.cpp $CFLAGS
./cstr runtime.lua util.lua macro.lua main.lua init.lua blud.lua builtin.blud debug.lua implicit.lua compiler.lua compile_io.lua >./bludlua.c

gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS
zip -u blud.zip *.c *.lua *.cpp *.h *.org builtin.blud

exit 0

g++ -o blud blud.cpp luawrap.cpp $LUAJIT_FLAGS $CFLAGS

