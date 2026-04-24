LDFLAGS="-L./luajit/src -lluajit"
CFLAGS="-Wall -Wextra -fmax-errors=2"
g++ -o cstr cstr.cpp $CFLAGS
./cstr main.lua init.lua blud.lua builtin.blud debug.lua implicit.lua >./bludlua.c

gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c -I/usr/local/include/luajit-2.1 $LDFLAGS $CFLAGS
exit 0

g++ -o blud blud.cpp luawrap.cpp -I/usr/local/include/luajit-2.1 $LDFLAGS $CFLAGS
