@testset "BufWriter construction" begin
    # Test basic construction
    io = IOBuffer()
    writer = BufWriter(io)
    @test writer isa BufWriter{IOBuffer}

    # Test custom buffer size
    writer2 = BufWriter(io, 1024)
    @test length(writer2.buffer) == 1024

    # Test minimum buffer size
    writer3 = BufWriter(io, 1)
    @test length(writer3.buffer) == 1

    # Test invalid buffer size
    @test_throws ArgumentError BufWriter(io, 0)
    @test_throws ArgumentError BufWriter(io, -1)
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
    @test length(writer.buffer) > 5
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
    close(writer)
    close(writer)
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

@testset "Write numbers" begin
    io = IOBuffer()
    writer = BufWriter(io, 3)
    write(writer, 0x01)
    write(writer, htol(0x0302))
    write(writer, 0x07060504)
    write(writer, 0x0f0e0d0c0b0a0908)
    write(writer, 1.2443)
    shallow_flush(writer)
    data = take!(io)
    @test data[1:15] == 1:15
    @test reinterpret(Float64, data[16:23]) == [1.2443]
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
    @test filesize(writer) == 0  # Filesize does not include buffered data

    # Flush and check again
    flush(writer)
    @test position(writer) == 5
    @test filesize(writer) == 5

    # Write more data
    write(writer, " world")
    @test position(writer) == 11
    @test filesize(writer) == 5  # Still only flushed data

    # Partial flush via shallow_flush
    shallow_flush(writer)
    @test position(writer) == 11
    @test filesize(writer) == 11

    # Write after flush
    write(writer, "!")
    @test position(writer) == 12
    @test filesize(writer) == 11

    close(writer)
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
    @test filesize(writer2) == 0  # Not flushed yet

    # Seek should flush first
    seek(writer2, 0)
    @test position(writer2) == 0
    @test filesize(writer2) == 5  # Now flushed
    write(writer2, "HELLO")
    flush(writer2)
    seekstart(io2)
    @test read(io2, String) == "HELLO"

    close(writer2)

    # Test invalid seeks
    io3 = IOBuffer()
    writer3 = BufWriter(io3)
    write(writer3, "test")
    flush(writer3)

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
