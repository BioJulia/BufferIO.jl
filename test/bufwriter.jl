@testset "BufWriter construction" begin
    # Test basic construction
    io = IOBuffer()
    writer = BufWriter(io)
    @test writer isa BufWriter{IOBuffer}

    # Test custom buffer size
    writer2 = BufWriter(io, 1024)
    @test length(BufferIO.get_memory(writer2)) == 1024

    # Test minimum buffer size
    writer3 = BufWriter(io, 1)
    @test length(BufferIO.get_memory(writer3)) == 1

    # Test invalid buffer size
    @test_throws ArgumentError BufWriter(io, 0)
    @test_throws ArgumentError BufWriter(io, -1)
end

@testset "get_buffer of full buffer" begin
    # When the buffer is full, `consumed + 1` is one past the end of the
    # buffer. This must not create an out-of-bounds MemoryRef.
    io = IOBuffer()
    writer = BufWriter(io, 4)
    @test write(writer, "abcd") == 4
    @test isempty(get_buffer(writer))
    @test get_unflushed(writer) == b"abcd"
    @test grow_buffer(writer) == 4
    @test length(get_buffer(writer)) == 4
    @test grow_buffer(writer) > 0
    @test length(get_buffer(writer)) == length(BufferIO.get_memory(writer)) == writer.capacity
    resize_buffer(writer, 2)
    @test write(writer, "ef") == 2
    @test isempty(get_buffer(writer))
    @test get_unflushed(writer) == b"ef"
    flush(writer)
    @test take!(io) == b"abcdef"
end

@testset "get_buffer" begin
    io = IOBuffer()
    writer = BufWriter(io, 10)

    # Initial buffer should be full size
    buffer = get_buffer(writer)
    @test buffer isa MutableMemoryView{UInt8}
    @test length(buffer) == 10

    # After consuming some bytes
    consume(writer, 3)
    buffer2 = get_buffer(writer)
    @test length(buffer2) == 7

    # After consuming all bytes
    consume(writer, 7)
    buffer3 = get_buffer(writer)
    @test length(buffer3) == 0
end

@testset "get_unflushed" begin
    io = IOBuffer()
    writer = BufWriter(io, 10)

    # Initially no data
    data = get_unflushed(writer)
    @test data isa MutableMemoryView{UInt8}
    @test length(data) == 0

    # After writing some bytes
    buffer = get_buffer(writer)
    copyto!(buffer[1:5], "abcde")
    consume(writer, 5)
    @test get_unflushed(writer) == b"abcde"

    # After flushing
    flush(writer)
    data3 = get_unflushed(writer)
    @test length(data3) == 0
end

@testset "consume" begin
    io = IOBuffer()
    writer = BufWriter(io, 10)

    # Valid consume
    buflen = length(get_buffer(writer))
    consume(writer, 3)
    @test buflen - length(get_buffer(writer)) == 3

    # Consume remaining
    consume(writer, 7)
    @test isempty(get_buffer(writer))
    @test length(get_unflushed(writer)) == 10

    # Test bounds checking - should error when consuming more than available
    writer2 = BufWriter(IOBuffer(), 5)
    @test_throws IOError consume(writer2, 6)
    @test_throws IOError consume(writer2, -1)
end

@testset "grow_buffer and shallow_flush" begin
    io = IOBuffer()
    writer = BufWriter(io, 5)

    # Fill buffer partially
    consume(writer, 3)

    # grow_buffer should flush when there's data
    n_grown = grow_buffer(writer)
    @test n_grown == 3  # bytes flushed
    @test isempty(get_unflushed(writer))
    @test length(get_buffer(writer)) == 5

    # grow_buffer on empty buffer should expand
    n_grown2 = grow_buffer(writer)
    @test n_grown2 > 0  # buffer expanded
    @test length(BufferIO.get_memory(writer)) > 5
end

@testset "flush and close" begin
    io = IOBuffer()
    writer = BufWriter(io, 10)

    # Write some data by consuming
    buffer = get_buffer(writer)
    buffer[1:5] .= b"hello"
    consume(writer, 5)

    # Data should not be in underlying IO yet
    seekstart(io)
    @test isempty(read(io))

    # Flush should write to underlying IO
    flush(writer)
    seekstart(io)
    @test read(io, String) == "hello"

    # Closing twice should be safe
    @test isopen(writer)
    close(writer)
    @test !isopen(writer)
    @test !isopen(io)
    close(writer)
    @test !isopen(writer)

    # Closed writer can't be written to
    @test isempty(get_buffer(writer))
    @test isempty(get_unflushed(writer))
    @test_throws IOError write(writer, "a")
    @test_throws IOError write(writer, 0x01)
end

# IO which fails when written to
mutable struct FailingWriteIO <: IO
    is_closed::Bool
end

Base.unsafe_write(::FailingWriteIO, ::Ptr{UInt8}, ::UInt) = error("write failed")
Base.close(x::FailingWriteIO) = (x.is_closed = true; nothing)

@testset "close when underlying IO throws" begin
    io = FailingWriteIO(false)
    writer = BufWriter(io)
    write(writer, "abc")
    @test_throws ErrorException close(writer)
    # Both the writer and the underlying IO are closed, even though writing failed
    @test !isopen(writer)
    @test io.is_closed
    @test_throws IOError write(writer, "abc")
    @test isnothing(close(writer))
end

@testset "write UInt8" begin
    io = IOBuffer()
    writer = BufWriter(io, 10)

    # Write single byte
    n = write(writer, 0x42)
    @test n == 1
    @test get_unflushed(writer) == [0x42]

    flush(writer)
    seekstart(io)
    @test read(io, UInt8) == 0x42
end

@testset "write with small buffer" begin
    io = IOBuffer()
    writer = BufWriter(io, 3)  # Very small buffer

    # Write data larger than buffer
    data = "Hello, world!"
    n = write(writer, data)
    @test n == length(data)

    # Should have automatically flushed
    flush(writer)
    seekstart(io)
    @test read(io, String) == data

    # A write too large to fit in buffer, but too small to
    # cause the BufWriter to skip the buffer altogether.
    io = IOBuffer()
    writer = BufWriter(io, 7)
    write(writer, "John") # write to buffer
    write(writer, " the ") # flush, then write to buffer
    write(writer, "baptist") # flush, then write to io directly
    flush(writer)
    @test String(take!(io)) == "John the baptist"
end

@testset "get_nonempty_buffer" begin
    io = IOBuffer()
    writer = BufWriter(io, 5)

    # Should return non-empty buffer initially
    buffer = get_nonempty_buffer(writer)
    @test buffer !== nothing
    @test !isempty(buffer)
    @test length(buffer) == 5

    # After filling buffer
    consume(writer, 5)
    buffer2 = get_nonempty_buffer(writer)
    @test buffer2 !== nothing  # Should grow or flush
    @test !isempty(buffer2)

    # Two-arg method
    writer = BufWriter(IOBuffer(), 3)
    write(writer, 0x61)
    buf = get_nonempty_buffer(writer, 2)
    @test length(buf) == 2
    @test get_unflushed(writer) == [0x61]
    buf = get_nonempty_buffer(writer, 3)
    @test length(buf) == 3
    @test isempty(get_unflushed(writer))
    write(writer, "abc")
    buf = get_nonempty_buffer(writer, 101)
    @test length(get_nonempty_buffer(writer)) ≥ 101

    # Nonpositive min_size still returns a nonempty buffer when full
    for min_size in (0, -5)
        writer = BufWriter(IOBuffer(), 3)
        write(writer, "abc")
        @test !isempty(get_nonempty_buffer(writer, min_size))
    end

    # The two-arg method never returns `nothing`, and the compiler knows it
    writer = BufWriter(IOBuffer(), 3)
    @test (@inferred get_nonempty_buffer(writer, 100)) isa MutableMemoryView{UInt8}
end

@testset "edge cases" begin
    # Test with buffer size 1
    io = IOBuffer()
    writer = BufWriter(io, 1)

    write(writer, "abc")  # Should handle automatic flushing
    flush(writer)
    seekstart(io)
    @test read(io, String) == "abc"

    # Test writing empty string
    io2 = IOBuffer()
    writer2 = BufWriter(io2)
    @test write(writer2, "") == 0
    seekstart((io2))
    @test isempty(take!(io2))

    # Test multiple flushes
    io3 = IOBuffer()
    writer3 = BufWriter(io3)
    write(writer3, "test")
    flush(writer3)
    flush(writer3)  # Should be safe
    seekstart(io3)
    @test read(io3, String) == "test"
end

@testset "error conditions" begin
    io = IOBuffer()
    writer = BufWriter(io, 5)

    # Test consuming more than buffer size
    @test_throws IOError consume(writer, 10)

    # Test consuming negative amount
    @test_throws IOError consume(writer, -1)

    # Test that errors have correct kind
    try
        consume(writer, 10)
        @test false  # Should not reach here
    catch e
        @test e isa IOError
        @test e.kind == IOErrorKinds.ConsumeBufferError
    end
end

@testset "resize_buffer" begin
    io = IOBuffer()
    writer = BufWriter(io, 10)
    mem = parent(get_buffer(writer))
    write(writer, "abcdefghijklmnopq")
    @test parent(get_buffer(writer)) === mem

    # Resize to same size does nothing
    resize_buffer(writer, 10)
    @test parent(get_buffer(writer)) === mem

    # Resize larger
    resize_buffer(writer, 12)
    newmem = parent(get_buffer(writer))
    @test length(newmem) == 12
    @test newmem !== mem
    shallow_flush(writer)

    # Resize smaller
    resize_buffer(writer, 6)
    newmem = parent(get_buffer(writer))
    @test length(newmem) == 6
    @test newmem !== mem

    # Can't resize to zero or negative
    @test_throws ArgumentError resize_buffer(writer, 0)
    @test_throws ArgumentError resize_buffer(writer, -1)

    # Can't resize to lower than written size
    io = IOBuffer()
    writer = BufWriter(io, 10)
    write(writer, "abcd")
    resize_buffer(writer, 4)
    @test length(parent(get_buffer(writer))) == 4
    @test length(get_unflushed(writer)) == 4
    @test_throws ArgumentError resize_buffer(writer, 3)
    shallow_flush(writer)
    resize_buffer(writer, 3)
    @test length(parent(get_buffer(writer))) == 3
end

@testset "position and filesize" begin
    # Test initial position and filesize
    io = IOBuffer()
    writer = BufWriter(io, 10)
    @test position(writer) == 0
    @test filesize(writer) == 0

    # Write some data (buffered, not flushed)
    write(writer, "hello")
    @test position(writer) == 5  # Position includes buffered data
    @test filesize(writer) == 5  # Filesize includes buffered data
    @test isempty(take!(copy(io))) # Nothing has been flushed

    # Flush and check again
    flush(writer)
    @test position(writer) == 5
    @test filesize(writer) == 5

    # Write more data
    write(writer, " world")
    @test position(writer) == 11
    @test filesize(writer) == 11

    # Partial flush via shallow_flush
    shallow_flush(writer)
    @test position(writer) == 11
    @test filesize(writer) == 11

    # Write after flush
    write(writer, "!")
    @test position(writer) == 12
    @test filesize(writer) == 12

    # Overwriting buffered data within the file does not change the filesize
    seek(writer, 2)
    write(writer, "LL")
    @test position(writer) == 4
    @test filesize(writer) == 12

    # Writing past the end of the file extends it
    seek(writer, 10)
    write(writer, "abcd")
    @test position(writer) == 14
    @test filesize(writer) == 14
    flush(writer)
    @test String(take!(io)) == "heLLo worlabcd"

    close(writer)
    @test_throws IOError filesize(writer)
    @test_throws IOError position(writer)
end

@testset "position and filesize with IOStream" begin
    # IOStream has its own buffer, and its filesize does not include it.
    path = tempname()
    try
        writer = BufWriter(open(path, "w"), 10)
        write(writer, "hello")
        @test filesize(writer) == 5
        shallow_flush(writer) # into the buffer of the IOStream
        @test filesize(writer) == 5
        write(writer, " world")
        @test (position(writer), filesize(writer)) == (11, 11)
        seek(writer, 1)
        @test (position(writer), filesize(writer)) == (1, 11)
        write(writer, "E")
        @test seekend(writer) === writer
        @test (position(writer), filesize(writer)) == (11, 11)
        write(writer, "!")
        close(writer)
        @test read(path, String) == "hEllo world!"
    finally
        rm(path; force = true)
    end
end

@testset "seek functionality" begin
    # Test basic seeking
    io = IOBuffer()
    writer = BufWriter(io, 10)

    # Write initial data
    write(writer, "0123456789")
    flush(writer)
    @test filesize(writer) == 10

    # Seek to beginning
    seek(writer, 0)
    @test position(writer) == 0
    write(writer, "AB")
    flush(writer)
    seekstart(io)
    @test read(io, String) == "AB23456789"

    # Seek to middle
    seek(writer, 5)
    @test position(writer) == 5
    write(writer, "XYZ")
    flush(writer)
    seekstart(io)
    @test read(io, String) == "AB234XYZ89"

    # Seek to end
    seek(writer, filesize(writer))
    @test position(writer) == filesize(writer)
    write(writer, "END")
    flush(writer)
    seekstart(io)
    @test read(io, String) == "AB234XYZ89END"

    close(writer)

    # Test seeking with buffered data
    io2 = IOBuffer()
    writer2 = BufWriter(io2, 10)
    write(writer2, "hello")
    @test position(writer2) == 5
    @test filesize(writer2) == 5

    # Seeking backwards into unflushed data is valid, and keeps the data
    seek(writer2, 3)
    @test position(writer2) == 3
    @test filesize(writer2) == 5
    write(writer2, "L")
    flush(writer2)
    seekstart(io2)
    @test read(io2, String) == "helLo"

    seek(writer2, 0)
    write(writer2, "HELLO")
    flush(writer2)
    seekstart(io2)
    @test read(io2, String) == "HELLO"

    close(writer2)

    # seekend accounts for unflushed data extending the file
    io2 = IOBuffer()
    writer2 = BufWriter(io2, 10)
    write(writer2, "abc")
    flush(writer2)
    seekstart(writer2)
    write(writer2, "ABCDEF")
    @test seekend(writer2) === writer2
    @test position(writer2) == 6
    write(writer2, "gh")
    flush(writer2)
    @test String(take!(io2)) == "ABCDEFgh"

    close(writer2)

    # Test invalid seeks
    io3 = IOBuffer()
    writer3 = BufWriter(io3)
    write(writer3, "test")
    flush(writer3)

    @test seek(writer3, Int32(1)) === writer3
    @test_throws IOError seek(writer3, Int8(-1))
    @test_throws IOError seek(writer3, -1)
    @test_throws IOError seek(writer3, filesize(writer3) + 1)

    # Verify error kind
    try
        seek(writer3, -1)
        @test false  # Should not reach
    catch e
        @test e isa IOError
        @test e.kind == IOErrorKinds.BadSeek
    end

    try
        seek(writer3, 100)
        @test false  # Should not reach
    catch e
        @test e isa IOError
        @test e.kind == IOErrorKinds.BadSeek
    end

    close(writer3)
    @test_throws IOError seek(writer3, 0)

    # An invalid seek leaves the writer unchanged
    io4 = IOBuffer()
    writer4 = BufWriter(io4, 10)
    write(writer4, "abc")
    @test_throws IOError seek(writer4, 4)
    @test get_unflushed(writer4) == b"abc"
    @test isempty(take!(copy(io4)))
    @test position(writer4) == 3
end

@testset "Automatic closing" begin
    io = IOBuffer()
    try
        BufWriter(io) do writer
            write(writer, 0x61)
            write(writer, "bc")
            @test position(io) == 0
            seekstart(io)
            @test read(io) == UInt8[]
            shallow_flush(writer)
            seekstart(io)
            @test read(io) == b"abc"
            seekstart(io)
            error()
        end
    catch
        nothing
    end
    @test !iswritable(io)
    @test_throws Exception read(io)
end

@testset "take_inner" begin
    io = IOBuffer()
    writer = BufWriter(io, 8)
    write(writer, "abc")
    @test take_inner(writer) === io
    @test !isopen(writer)
    # Buffered data was written to io
    @test take!(io) == b"abc"
    @test isopen(io)

    # The writer can no longer access io, or be written to
    @test isempty(get_buffer(writer))
    @test isempty(get_unflushed(writer))
    is_closed_err(e) = e isa IOError && e.kind == IOErrorKinds.ClosedIO
    for f in [
            flush,
            shallow_flush,
            grow_buffer,
            w -> write(w, "a"),
            w -> write(w, 0x01),
            w -> resize_buffer(w, 100),
            w -> write(w, "a long string which does not fit in the buffer"),
            w -> (write(w, "abcdefgh"); write(w, 0x01)),
            w -> get_nonempty_buffer(w, 100),
            w -> seek(w, 0),
            position,
            filesize,
            take_inner,
        ]
        @test try
            f(writer)
            false
        catch e
            is_closed_err(e)
        end
    end
    close(writer)
    @test isopen(io)
    @test isempty(take!(io))

    # Closed writer cannot be taken from
    writer = BufWriter(IOBuffer())
    close(writer)
    @test_throws IOError take_inner(writer)
end
