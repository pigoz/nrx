all: build

build: *.m
	clang -Wall -o nrx nrx.m `pkg-config --libs --cflags mpv` -framework Cocoa -framework OpenGL

fmt:
	clang-format -i nrx.m

clean:
	rm nrx
