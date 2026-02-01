# Makefile for Zig NMDC Workspace

.PHONY: all lib server client clean run-server run-client

all: lib server client

lib:
	cd lib && zig build

server:
	cd server && zig build

client:
	cd client && zig build

run-server:
	cd server && zig build run

run-client:
	cd client && zig build run

clean:
	rm -rf lib/zig-out server/zig-out client/zig-out
