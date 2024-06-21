CFLAGS="-std=c++23 -Wall -Wextra -fmax-errors=2"
LDFLAGS="-L./luajit/src -lluajit"
g++ -o cstr cstr.cpp $CFLAGS
g++ -o blud blud.cpp luawrap.cpp -I/usr/local/include/luajit-2.1 $LDFLAGS $CFLAGS
