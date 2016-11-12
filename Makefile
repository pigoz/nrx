all: build

build: *.m
	clang -Wall -o nrx nrx.m `pkg-config --libs --cflags mpv` -framework Cocoa -framework OpenGL

clean:
	rm nrx
