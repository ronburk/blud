BUILD_ID=$(($(cat .build_id 2>/dev/null || echo 0) + 1))
echo $BUILD_ID > .build_id
if [ -d /mnt/data/LuaJIT-2.1/src ]; then
    LUAJIT_FLAGS="-I/mnt/data/LuaJIT-2.1/src -L/mnt/data/LuaJIT-2.1/src -Wl,-rpath,/mnt/data/LuaJIT-2.1/src -lluajit"
else
    LUAJIT_FLAGS="$(pkg-config --cflags --libs luajit) -Wl,-rpath,/usr/local/lib"
fi
#LUAJIT_FLAGS="$(pkg-config --cflags --libs luajit)"
#LUAJIT_FLAGS="$(pkg-config --cflags --libs luajit) -Wl,-rpath,/usr/local/lib"
#LDFLAGS="-L./luajit/src -lluajit"
CFLAGS="-Wall -Wextra -fmax-errors=2"
# build cstr utility
g++ -o cstr cstr.cpp $CFLAGS
./cstr runtime.lua util.lua macro.lua main.lua init.lua blud.lua builtin.blud debug.lua implicit.lua compiler.lua compile_io.lua operator.lua >./bludlua.c

gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS -DBUILD_ID=$BUILD_ID
#gcc -MMD -MP -o blud blud.c bludlua.c oslinux.c $LUAJIT_FLAGS $CFLAGS
zip -u blud.zip *.c *.lua *.cpp *.h *.org builtin.blud build.sh test.blud test/* bludfile

exit 0

g++ -o blud blud.cpp luawrap.cpp $LUAJIT_FLAGS $CFLAGS
rm ./*.luad
