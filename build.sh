LDFLAGS="-L./luajit/src -lluajit"
CFLAGS="-std=c++23 -Wall -Wextra -fmax-errors=2"
g++ -o cstr cstr.cpp $CFLAGS
./cstr blud.lua >./bludlua.c

gcc -o blud blud.c -I/usr/local/include/luajit-2.1 $LDFLAGS
exit 0

g++ -o blud blud.cpp luawrap.cpp -I/usr/local/include/luajit-2.1 $LDFLAGS $CFLAGS
