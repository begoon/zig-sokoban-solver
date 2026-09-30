default: test build

build:
    zig build

test:
    zig build test

install:
    zig build install

clean:
    zig build clean

wasm:
    zig build wasm

web:
    zig build web

serve: web
    python3 -m http.server 8000 --bind 127.0.0.1 --directory zig-out/web

test-web: web
    bun test scripts/web.test.js
