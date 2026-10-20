@testset "BufReader construction" begin
    # Test basic construction
    io = IOBuffer("hello world")
    reader = BufReader(io)
    @test reader isa BufReader
    @test reader.io === io

    # Test with custom buffer size
    io2 = IOBuffer("test")
    reader2 = BufReader(io2, 16)
    @test length(reader2.ref.mem) == 16

    # Test invalid buffer sizes
    io3 = IOBuffer("test")
    @test_throws ArgumentError BufReader(io3, 0)
    @test_throws ArgumentError BufReader(io3, -1)

    # Test that buffer starts empty
    @test isempty(get_buffer(reader))
end

@testset "get_buffer of fully consumed buffer" begin
    # When the whole buffer is filled and consumed, `start` is one past the
    # end of the buffer. This must not create an out-of-bounds MemoryRef.
    reader = BufReader(IOBuffer("abcdefgh"), 4)
    @test fill_buffer(reader) == 4
    @test get_buffer(reader) == b"abcd"
    consume(reader, 4)
    @test isempty(get_buffer(reader))
    @test read(reader) == b"efgh"
    @test isempty(get_buffer(reader))
    # Relative seeking backwards within the buffer still works when empty
    BufferIO.relative_seek(reader, -2)
    @test read(reader) == b"gh"
end

@testset "get_buffer and fill_buffer" begin
    io = IOBuffer("hello world")
    reader = BufReader(io, 4)  # Small buffer

    # Initially empty
    @test isempty(get_buffer(reader))

    # Fill buffer
    n_filled = fill_buffer(reader)
    @test n_filled == 4  # Should fill to buffer capacity
    buffer = get_buffer(reader)
    @test length(buffer) == 4
    @test String(buffer) == "hell"

    # Fill again (should expand or move data)
    consume(reader, 2)  # Consume "he"
    n_filled2 = fill_buffer(reader)
    @test n_filled2 > 0
    buffer2 = get_buffer(reader)
    @test String(buffer2[1:2]) == "ll"  # Previous unconsumed data
    n_filled3 = fill_buffer(reader)
    @test n_filled3 == 5
    @test String(get_buffer(reader)) == "llo world"

    # Test EOF behavior
    io_eof = IOBuffer("")
    reader_eof = BufReader(io_eof)
    @test fill_buffer(reader_eof) == 0

    # Test consume too much
    io = IOBuffer("test")
    reader = BufReader(io, 10)
    fill_buffer(reader)
    @test length(get_buffer(reader)) == 4
    @test_throws IOError consume(reader, 5)
end

@testset "Position tracking" begin
    io = IOBuffer("hello world test")
    reader = BufReader(io, 5)

    # Initial position
    @test position(reader) == 0

    # Read some data
    read(reader, 5)  # "hello"
    @test position(reader) == 5

    # Read more
    read(reader, 6)  # " world"
    @test position(reader) == 11

    # Fill buffer and check position consistency
    fill_buffer(reader)
    @test position(reader) == 11  # Should account for buffered data

    # Consume from buffer
    consume(reader, 2) # consume " t"
    @test position(reader) == 13

    # Read remaining
    remaining = read(reader)
    @test String(remaining) == "est"
    @test position(reader) == 16  # End of data
end

@testset "seek functionality" begin
    io = IOBuffer("0123456789")
    reader = BufReader(io, 4)

    # Test seeking to beginning
    seek(reader, 0)
    @test position(reader) == 0
    @test String(read(reader, 3)) == "012"

    # Test seeking forward
    seek(reader, 5)
    @test position(reader) == 5
    @test String(read(reader, 2)) == "56"

    # Test seeking backward
    seek(reader, 2)
    @test position(reader) == 2
    @test String(read(reader, 3)) == "234"

    # Test seeking to end
    seek(reader, 10)
    @test position(reader) == 10
    @test isempty(read(reader))
    @test eof(reader)

    # Test invalid seeks
    @test_throws IOError seek(reader, -1)
    @test_throws IOError seek(reader, 11)  # Beyond end
end

function test_bad_relative_seek(io, delta)
    return try
        relative_seek(io, delta)
        @test false
    catch e
        if e isa IOError && e.kind == IOErrorKinds.BadSeek
            @test true
        else
            rethrow()
        end
    end
end

@testset "Relative seek" begin
    reader = BufReader(IOBuffer("0123456789"), 4)
    test_bad_relative_seek(reader, -1)
    test_bad_relative_seek(reader, 11)
    relative_seek(reader, 3)
    @test read(reader) == b"3456789"

    reader = BufReader(IOBuffer("0123456789"), 4)
    relative_seek(reader, 2)
    @test read(reader, UInt8) == UInt8('2')
    test_bad_relative_seek(reader, -4)
    test_bad_relative_seek(reader, 8)
    relative_seek(reader, -2)
    @test read(reader, UInt8) == UInt8('1')

    reader = BufReader(IOBuffer("0123456789"), 4)
    relative_seek(reader, 10)
    @test eof(reader)
    relative_seek(reader, 0)
    test_bad_relative_seek(reader, 1)
    test_bad_relative_seek(reader, -11)

    reader = BufReader(IOBuffer("0123456789"), 4)
    relative_seek(reader, 6)
    @test read(reader) == b"6789"
    relative_seek(reader, -3)
    @test read(reader) == b"789"
    relative_seek(reader, -8)
    @test read(reader) == b"23456789"
end

@testset "filesize compatibility" begin
    # Test that seek works with filesize bounds
    io = IOBuffer("test data")
    reader = BufReader(io)

    # filesize should work with IOBuffer
    @test filesize(io) == 9

    # Seeking within bounds
    seek(reader, 0)
    @test position(reader) == 0
    seek(reader, filesize(io))
    @test position(reader) == filesize(io)
    @test eof(reader)

    # Seeking beyond bounds should fail
    @test_throws IOError seek(reader, filesize(io) + 1)
end

@testset "resize_buffer" begin
    io = BufReader(IOBuffer("abcdef"))
    @test_throws ArgumentError resize_buffer(io, 0)
    resize_buffer(io, 1)
    resize_buffer(io, 10)
    fill_buffer(io)
    @test length(get_buffer(io)) == 6
    @test_throws ArgumentError resize_buffer(io, 5)
    resize_buffer(io, 7)
    @test read(io) == b"abcdef"
    resize_buffer(io, 2)
    seekstart(io)
    @test read(io) == b"abcdef"
end

@testset "Automatic closing" begin
    io = IOBuffer("hello, world!")
    try
        BufReader(io, 3) do reader
            fill_buffer(reader)
            @test readavailable(reader) == b"hel"
            error()
        end
    catch
        nothing
    end
    @test !isreadable(io)
end

@testset "isopen" begin
    io = IOBuffer("hello")
    reader = BufReader(io)
    @test isopen(reader)
    close(reader)
    @test !isopen(reader)
    @test !isopen(io)
end

@testset "take_inner" begin
    io = IOBuffer("abcdefghij")
    reader = BufReader(io, 4)
    @test read(reader, 2) == b"ab"
    @test take_inner(reader) === io
    @test !isopen(reader)
    # Buffered "cd" is discarded, and the reader is empty
    @test isempty(get_buffer(reader))
    @test isopen(io)
    @test position(io) == 4

    # The reader can no longer access io
    is_closed_err(e) = e isa IOError && e.kind == IOErrorKinds.ClosedIO
    for f in [
            fill_buffer,
            r -> read(r, UInt8),
            read,
            r -> read(r, 3),
            readline,
            r -> skip(r, 2),
            r -> seek(r, 0),
            r -> seek(r, 6),
            r -> relative_seek(r, 1),
            r -> relative_seek(r, -1),
            position,
            take_inner,
        ]
        @test try
            f(reader)
            false
        catch e
            is_closed_err(e)
        end
    end
    close(reader)
    @test isopen(io)
    @test position(io) == 4
    @test read(io, String) == "efghij"

    # Closed reader cannot be taken from
    reader = BufReader(IOBuffer("abc"))
    close(reader)
    @test_throws IOError take_inner(reader)
    @test_throws IOError read(reader, UInt8)
    close(reader) # closing twice is fine
end

@testset "read_into! bypasses buffer for large reads" begin
    # Destination at least as large as the buffer: read directly from the IO
    reader = BufReader(IOBuffer("abcdefghijkl"), 4)
    v = MemoryView(zeros(UInt8, 8))
    @test read_into!(reader, v) == 8
    @test v == b"abcdefgh"
    @test isempty(get_buffer(reader))
    @test position(reader) == 8

    # Exactly the buffer size also bypasses
    v = MemoryView(zeros(UInt8, 4))
    @test read_into!(reader, v) == 4
    @test v == b"ijkl"
    @test isempty(get_buffer(reader))
    @test iszero(read_into!(reader, v))
    @test eof(reader)

    # Smaller destination goes through the buffer
    reader = BufReader(IOBuffer("abcdefghijkl"), 8)
    v = MemoryView(zeros(UInt8, 3))
    @test read_into!(reader, v) == 3
    @test v == b"abc"
    @test get_buffer(reader) == b"defgh"

    # Nonempty buffer is drained first, without reading from the IO
    v = MemoryView(zeros(UInt8, 10))
    @test read_into!(reader, v) == 5
    @test v[1:5] == b"defgh"
    @test read_into!(reader, v) == 4
    @test v[1:4] == b"ijkl"
    @test iszero(read_into!(reader, v))

    # Closed reader throws on the bypass path too
    reader = BufReader(IOBuffer("abcdefghijkl"), 4)
    close(reader)
    @test_throws IOError read_into!(reader, MemoryView(zeros(UInt8, 8)))
end

@testset "BufReader of IOStream" begin
    # Larger than IOStream's internal 32 KiB buffer, so both the buffered path
    # and the path bypassing IOStream's buffer are exercised
    data = rand(UInt8, 300_000)
    path, io = mktemp()
    write(io, data)
    close(io)
    try
        for bufsize in (1, 7, 4096, 2^15, 2^17, 2^20)
            # Fill buffer and drain
            reader = BufReader(open(path), bufsize)
            @test read(reader) == data
            @test eof(reader)
            @test iszero(fill_buffer(reader))
            close(reader)

            # Read through read_into! with various destination sizes,
            # both smaller and larger than the buffer
            for dstsize in (3, 1000, 50_000, 400_000)
                reader = BufReader(open(path), bufsize)
                dst = MemoryView(zeros(UInt8, dstsize))
                result = UInt8[]
                while true
                    n = read_into!(reader, dst)
                    iszero(n) && break
                    append!(result, dst[1:n])
                end
                @test result == data
                @test iszero(read_into!(reader, dst))
                close(reader)
            end
        end

        # Buffer is full when filled, so it must be grown
        reader = BufReader(open(path), 2^15)
        @test fill_buffer(reader) == 2^15
        consume(reader, 100)
        @test fill_buffer(reader) > 0
        @test length(get_buffer(reader)) > 2^15 - 100
        @test get_buffer(reader)[1:100] == data[101:200]
        @test read(reader) == data[101:end]
        close(reader)

        # Full buffer at EOF does not grow the buffer
        reader = BufReader(open(path), length(data))
        @test fill_buffer(reader) == length(data)
        @test iszero(fill_buffer(reader))
        @test length(reader.ref.mem) == length(data)
        close(reader)

        # Default buffer size is larger for IOStream than for other IOs
        reader = BufReader(open(path))
        @test length(reader.ref.mem) == 65536
        @test read(reader) == data
        close(reader)
        @test BufReader(r -> length(r.ref.mem), open(path)) == 65536
        @test length(BufReader(IOBuffer(data)).ref.mem) == 8192

        # Empty file
        empty_path, io = mktemp()
        close(io)
        reader = BufReader(open(empty_path), 2^17)
        @test iszero(fill_buffer(reader))
        @test iszero(read_into!(reader, MemoryView(zeros(UInt8, 2^18))))
        @test read(reader) == UInt8[]
        close(reader)
        rm(empty_path)
    finally
        rm(path)
    end
end

@testset "BufReader moving buffered bytes" begin
    data = collect(UInt8, 1:15)

    # Few buffered bytes are moved to the beginning, even if there is room at the end
    reader = BufReader(IOBuffer(data), 10)
    @test fill_buffer(reader) == 10
    consume(reader, 8)
    mem = reader.ref.mem
    @test fill_buffer(reader) == 5
    @test reader.ref.mem === mem
    @test get_buffer(reader) == data[9:15]
    consume(reader, 5)
    @test reader.stop < length(mem)
    @test iszero(fill_buffer(reader))
    @test reader.start == 1
    @test get_buffer(reader) == data[14:15]

    # Many buffered bytes are not moved to make room for few bytes.
    # Instead, the buffer is grown.
    reader = BufReader(IOBuffer(data), 10)
    @test fill_buffer(reader) == 10
    consume(reader, 1)
    @test fill_buffer(reader) == 5
    @test length(reader.ref.mem) > 10
    @test get_buffer(reader) == data[2:15]

    # Full buffer at EOF is neither moved nor grown
    reader = BufReader(IOBuffer(data), 15)
    @test fill_buffer(reader) == 15
    consume(reader, 3)
    mem = reader.ref.mem
    @test iszero(fill_buffer(reader))
    @test reader.ref.mem === mem
    @test reader.start == 4
    @test get_buffer(reader) == data[4:15]

    # The total number of bytes moved is at most the number of bytes consumed,
    # no matter how filling and consuming is interleaved
    data = rand(UInt8, 100_000)
    for bufsize in (1, 2, 16, 1000), max_consume in (1, 4, 100, 2000)
        reader = BufReader(IOBuffer(data), bufsize)
        result = UInt8[]
        n_moved = 0
        while true
            mem = reader.ref.mem
            (start, n_buffered) = (reader.start, length(get_buffer(reader)))
            n_filled = fill_buffer(reader)
            # Bytes were moved within the same memory
            if reader.ref.mem === mem && reader.start != start
                n_moved += n_buffered
            end
            buffer = get_buffer(reader)
            iszero(n_filled) && isempty(buffer) && break
            n = min(length(buffer), rand(1:max_consume))
            append!(result, buffer[1:n])
            consume(reader, n)
        end
        @test result == data
        @test n_moved ≤ length(data)
    end
end
