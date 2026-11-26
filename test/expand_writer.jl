@testset "ExpandWriter construction" begin
    inner = BlockWriter(4)
    io = ExpandWriter(inner)
    @test io isa ExpandWriter{BlockWriter}
    @test io.inner === inner
    @test ExpandWriter{BlockWriter}(BlockWriter(4)) isa ExpandWriter{BlockWriter}

    # Initial state
    @test length(get_buffer(io)) == 4
    @test isopen(io)
    @test position(io) == 0
    @test filesize(io) == 0
end

@testset "ExpandWriter forwards inner buffer" begin
    io = ExpandWriter(BlockWriter(4))
    @test get_buffer(io) === get_buffer(io.inner)
    @test !io.serving_own

    # Consuming is forwarded to inner
    get_buffer(io)[1:3] .= codeunits("abc")
    consume(io, 3)
    @test length(get_buffer(io)) == 1
    @test io.inner.n_buffered == 3
    @test_throws IOError consume(io, 2)

    # When inner can grow its buffer, its growth is forwarded
    @test grow_buffer(io) == 3
    @test !io.serving_own
    @test io.inner.data == b"abc"

    # Writes are forwarded to inner, even if larger than inner's buffer
    @test write(io, "defghijkl") == 9
    @test !io.serving_own
    flush(io)
    @test String(copy(io.inner.data)) == "abcdefghijkl"
end

@testset "ExpandWriter expands buffer" begin
    io = ExpandWriter(BlockWriter(4))

    # Inner's buffer can't grow, so own buffer is used
    n = grow_buffer(io)
    @test n > 0
    @test io.serving_own
    @test length(get_buffer(io)) == 4 + n

    # Consuming from own buffer
    buffer = get_buffer(io)
    buffer[1:10] .= codeunits("0123456789")
    consume(io, 10)
    @test length(get_buffer(io)) == 4 + n - 10
    @test_throws IOError consume(io, 4 + n - 9)
    @test_throws IOError consume(io, -1)
    @test isempty(io.inner.data)
    @test position(io) == 10

    # Pending bytes are written to inner when flushing
    flush(io)
    @test String(copy(io.inner.data)) == "0123456789"
    @test position(io) == 10
    @test filesize(io) == 10

    # Writing data to own buffer
    @test write(io, "abc") == 3
    @test io.serving_own
    flush(io)
    @test String(copy(io.inner.data)) == "0123456789abc"
end

@testset "ExpandWriter grow_buffer when serving own" begin
    # When the own buffer is mostly consumed, pending bytes are written to inner,
    # and io switches back to inner's buffer
    io = ExpandWriter(BlockWriter(8))
    grow_buffer(io)
    @test io.serving_own
    mem = io.mem
    n = length(get_buffer(io))
    write_repeated(io, UInt8('a'), n - 1)
    @test length(get_buffer(io)) == 1
    @test grow_buffer(io) == length(get_buffer(io)) - 1
    @test !io.serving_own
    @test length(io.inner.data) + io.inner.n_buffered == n - 1
    @test io.mem === mem

    # If inner can't provide a larger buffer, the own buffer is kept, after writing
    # its pending bytes to inner
    io = ExpandWriter(BlockWriter(4))
    grow_buffer(io)
    write_repeated(io, UInt8('a'), 4)
    mem = io.mem
    n_old = length(get_buffer(io))
    @test grow_buffer(io) == 4
    @test io.serving_own
    @test io.mem === mem
    @test length(get_buffer(io)) == n_old + 4
    flush(io.inner)
    @test io.inner.data == fill(UInt8('a'), 4)

    # If no bytes are pending, the own buffer is reallocated larger
    n_old = length(get_buffer(io))
    n = grow_buffer(io)
    @test n > 0
    @test io.mem !== mem
    @test length(get_buffer(io)) == n_old + n

    # After switching back to inner, the own memory is reused
    io = ExpandWriter(BlockWriter(8))
    grow_buffer(io)
    mem = io.mem
    write_repeated(io, UInt8('a'), length(get_buffer(io)))
    grow_buffer(io)
    @test !io.serving_own
    write_repeated(io, UInt8('b'), length(get_buffer(io)))
    grow_buffer(io)
    @test !io.serving_own
    grow_buffer(io)
    @test io.serving_own
    @test io.mem === mem
end

@testset "ExpandWriter get_nonempty_buffer" begin
    # Inner's buffer is forwarded if inner can provide enough room
    io = ExpandWriter(BlockWriter(8))
    write(io, "abcde")
    @test length(get_nonempty_buffer(io, 6)) == 8
    @test !io.serving_own
    @test io.inner.data == b"abcde"

    # Else, the own buffer is allocated once with room for all the bytes
    io = ExpandWriter(BlockWriter(4))
    write(io, "ab")
    buffer = get_nonempty_buffer(io, 10)
    @test io.serving_own
    @test length(buffer) == length(io.mem) == BufferIO.overallocation_size(UInt(10))
    buffer[1:10] .= codeunits("cdefghijkl")
    consume(io, 10)
    @test position(io) == 12
    flush(io)
    @test String(copy(io.inner.data)) == "abcdefghijkl"

    # When the own buffer has too little room, pending bytes are written to inner,
    # and inner's buffer is used if it is large enough
    io = ExpandWriter(BlockWriter(8))
    get_nonempty_buffer(io, 10)
    n = length(io.mem) - 2
    write_repeated(io, UInt8('a'), n)
    @test length(get_nonempty_buffer(io, 4)) ≥ 4
    @test !io.serving_own
    flush(io)
    @test io.inner.data == fill(UInt8('a'), n)

    # When serving own buffer with too little room, the pending bytes are written to inner,
    # and the own buffer is reused
    io = ExpandWriter(BlockWriter(4))
    get_nonempty_buffer(io, 10)
    mem = io.mem
    write_repeated(io, UInt8('a'), length(mem) - 2)
    buffer = get_nonempty_buffer(io, 8)
    @test io.serving_own
    @test io.mem === mem
    @test length(buffer) == length(mem)
    flush(io)
    @test io.inner.data == fill(UInt8('a'), length(mem) - 2)

    # Nonpositive min_size
    io = ExpandWriter(BlockWriter(4))
    @test length(get_nonempty_buffer(io, 0)) == 4
    @test length(get_nonempty_buffer(io, -1)) == 4
    write(io, "abcd")
    @test length(get_nonempty_buffer(io, 0)) == 4
    @test !io.serving_own

    # Expandable inners provide the buffer themselves
    io = ExpandWriter(BufWriter(IOBuffer(), 2))
    @test length(get_nonempty_buffer(io, 8)) == BufferIO.overallocation_size(UInt(8))
    @test !io.serving_own
    io = ExpandWriter(VecWriter())
    @test length(get_nonempty_buffer(io, 100)) ≥ 100
    @test !io.serving_own

    # A full inner can't provide any buffer, so WriterFull is thrown
    io = ExpandWriter(FixedWriter(0))
    @test_throws IOError get_nonempty_buffer(io, 1)
    @test !io.serving_own
    io = ExpandWriter(BlockWriter(4; max_size = 6))
    write(io, "abcdef")
    err = try
        get_nonempty_buffer(io, 1)
    catch e
        e
    end
    @test err isa IOError && err.kind == IOErrorKinds.WriterFull

    # But inner with room for some bytes gets an own buffer
    io = ExpandWriter(BlockWriter(4; max_size = 6))
    @test length(get_nonempty_buffer(io, 10)) ≥ 10
    @test io.serving_own

    io = ExpandWriter(BlockWriter(4))
    close(io)
    @test_throws IOError get_nonempty_buffer(io, 1)
end

@testset "ExpandWriter full inner" begin
    # grow_buffer never returns zero, but throws if inner is full
    io = ExpandWriter(FixedWriter(3))
    @test write(io, "abc") == 3
    err = try
        grow_buffer(io)
    catch e
        e
    end
    @test err isa IOError && err.kind == IOErrorKinds.WriterFull
    @test !io.serving_own
    @test_throws IOError write(io, 0x01)
    err = try
        write(io, "d")
    catch e
        e
    end
    @test err.kind == IOErrorKinds.WriterFull

    # If inner becomes full while writing the own buffer to inner, the remaining bytes are
    # kept pending, and WriterFull is thrown
    io = ExpandWriter(BlockWriter(4; max_size = 6))
    buffer = get_nonempty_buffer(io, 10)
    buffer[1:10] .= codeunits("0123456789")
    consume(io, 10)
    err = try
        flush(io)
    catch e
        e
    end
    @test err isa IOError && err.kind == IOErrorKinds.WriterFull
    @test String(copy(io.inner.data)) == "012345"
    @test io.serving_own
    @test position(io) == 10
    @test String(get_buffer(io.inner)) == ""
    @test io.n_pending == 4
    @test io.mem[1:4] == codeunits("6789")
    @test_throws IOError grow_buffer(io)
    @test_throws IOError seek(io, 0)
    @test_throws IOError take_inner(io)
    @test isopen(io)

    # Closing still closes the writer and inner, but throws
    @test_throws IOError close(io)
    @test !isopen(io)
    @test io.inner.closed
end

# Writer which has room for 2 bytes, and fails when closed
mutable struct FailingCloseWriter <: AbstractBufWriter
    const mem::Memory{UInt8}
    consumed::Int
    closed::Bool
end

FailingCloseWriter() = FailingCloseWriter(Memory{UInt8}(undef, 2), 0, false)

BufferIO.get_buffer(x::FailingCloseWriter) = MemoryView(x.mem)[(x.consumed + 1):end]
BufferIO.grow_buffer(::FailingCloseWriter) = 0
BufferIO.consume(x::FailingCloseWriter, n::Int) = (x.consumed += n; nothing)
Base.close(x::FailingCloseWriter) = (x.closed = true; error("close failed"))

@testset "ExpandWriter close when inner throws" begin
    # If both writing to and closing inner throws, the write error is propagated
    io = ExpandWriter(FailingCloseWriter())
    get_nonempty_buffer(io, 3)[1:3] .= codeunits("abc")
    consume(io, 3)
    @test_throws IOError(IOErrorKinds.WriterFull) close(io)
    @test !isopen(io)
    @test io.inner.closed

    # If only closing throws, that error is propagated
    io = ExpandWriter(FailingCloseWriter())
    @test_throws ErrorException("close failed") close(io)
    @test !isopen(io)
end

@testset "ExpandWriter unsafe_write" begin
    # When serving own buffer, small writes go to the own buffer
    io = ExpandWriter(BlockWriter(4))
    grow_buffer(io)
    data = collect(UInt8, 0x01:0xff)
    GC.@preserve data unsafe_write(io, pointer(data), UInt(3))
    @test io.serving_own
    @test io.n_pending == 3

    # Large writes go through the own buffer, writing it to inner as needed
    @test write(io, data) == 255
    flush(io)
    @test io.inner.data == [data[1:3]; data]

    # Write with Integer nbytes
    io = ExpandWriter(BlockWriter(4))
    GC.@preserve data unsafe_write(io, pointer(data), 10)
    flush(io)
    @test io.inner.data == data[1:10]
end

@testset "ExpandWriter position and filesize" begin
    io = ExpandWriter(BlockWriter(4))
    write(io, "abcdef")
    @test position(io) == 6
    @test filesize(io) == 6

    # Position when serving own buffer, with pending bytes
    buffer = get_nonempty_buffer(io, 8)
    @test io.serving_own
    @test position(io) == 6
    buffer[1:5] .= 0x00
    consume(io, 5)
    @test position(io) == 11
    @test filesize(io) == 11

    # Pending bytes overwrite existing data
    io = ExpandWriter(BlockWriter(4))
    write(io, "abcdefghijkl")
    seek(io, 2)
    get_nonempty_buffer(io, 8)[1:3] .= codeunits("XYZ")
    consume(io, 3)
    @test io.serving_own
    @test position(io) == 5
    @test filesize(io) == 12
    flush(io)
    @test String(copy(io.inner.data)) == "abXYZfghijkl"

    # Forwards to inner BufWriter
    buf = IOBuffer()
    io = ExpandWriter(BufWriter(buf))
    write(io, "abc")
    @test position(io) == 3
    @test filesize(io) == 3
end

@testset "ExpandWriter seek" begin
    io = ExpandWriter(BlockWriter(4))
    write(io, "abcdef")
    buffer = get_nonempty_buffer(io, 8)
    buffer[1:4] .= codeunits("ghij")
    consume(io, 4)
    @test io.serving_own

    # Invalid seeks do not change the writer
    @test_throws IOError seek(io, 11)
    @test_throws IOError seek(io, -1)
    @test io.serving_own
    @test position(io) == 10
    @test io.n_pending == 4

    # Seeking writes the pending bytes, and switches back to inner
    seek(io, 1)
    @test !io.serving_own
    @test position(io) == 1
    write(io, "XY")
    seekend(io)
    @test position(io) == 10
    write(io, "k")
    flush(io)
    @test String(copy(io.inner.data)) == "aXYdefghijk"

    # Seeking when not serving own buffer is forwarded
    @test_throws IOError seek(io, 12)
    seek(io, 0)
    @test position(io) == 0
end

@testset "ExpandWriter close" begin
    inner = BlockWriter(4)
    io = ExpandWriter(inner)
    write(io, "ab")
    get_nonempty_buffer(io, 10)[1:8] .= codeunits("cdefghij")
    consume(io, 8)
    @test isopen(io)

    # Closing writes pending bytes, closes inner, and releases own memory
    close(io)
    @test !isopen(io)
    @test inner.closed
    @test String(copy(inner.data)) == "abcdefghij"
    @test isempty(get_buffer(io))
    @test isempty(io.mem)

    # Closing is idempotent
    close(io)
    @test !isopen(io)

    # Operations on closed writer
    consume(io, 0)
    @test_throws IOError consume(io, 1)
    for f in [
            grow_buffer,
            flush,
            w -> write(w, 0x01),
            w -> write(w, "abc"),
            w -> get_nonempty_buffer(w, 1),
            position,
            filesize,
            w -> seek(w, 0),
            take_inner,
        ]
        err = try
            f(io)
            nothing
        catch e
            e
        end
        @test err isa IOError && err.kind == IOErrorKinds.ClosedIO
    end
    @test drop_own(io) === nothing
end

@testset "ExpandWriter take_inner" begin
    # When forwarding inner's buffer, inner keeps its buffered bytes
    inner = BlockWriter(4)
    io = ExpandWriter(inner)
    write(io, "abc")
    @test take_inner(io) === inner
    @test !isopen(io)
    @test !inner.closed
    @test inner.n_buffered == 3
    flush(inner)
    @test inner.data == b"abc"

    # When serving own buffer, pending bytes are written to inner
    inner = BlockWriter(4)
    io = ExpandWriter(inner)
    write(io, "ab")
    get_nonempty_buffer(io, 10)[1:8] .= codeunits("cdefghij")
    consume(io, 8)
    @test take_inner(io) === inner
    @test !inner.closed
    flush(inner)
    @test String(copy(inner.data)) == "abcdefghij"
    @test isempty(io.mem)
    close(io)
    @test !inner.closed

    # Closed writer cannot be taken from
    io = ExpandWriter(BlockWriter(4))
    close(io)
    @test_throws IOError take_inner(io)
end

@testset "ExpandWriter drop_own" begin
    # When own buffer is in use, it can't be dropped
    io = ExpandWriter(BlockWriter(4))
    get_nonempty_buffer(io, 10)
    mem = io.mem
    @test drop_own(io) === nothing
    @test io.mem === mem

    # When not in use, the own buffer is dropped and returned
    seek(io, 0)
    @test drop_own(io) === mem
    @test isempty(io.mem)

    # After dropping, own buffer is allocated again as needed
    @test length(get_nonempty_buffer(io, 10)) ≥ 10
    @test io.serving_own
    @test drop_own(io) === nothing
end

@testset "ExpandWriter randomized" begin
    # Simple PRNG to avoid depending on Random. Returns a number in 0:n-1
    state = UInt64(1)
    rand_below(n) = (state = state * 0x5851f42d4c957f2d + 0x14057b7ef767814f; Int((state >> 33) % n))

    # Random operations, compared against a VecWriter with the same writes
    io = ExpandWriter(BlockWriter(13))
    expected = UInt8[]
    pos = 0
    ok = true
    for _ in 1:3000
        r = rand_below(10)
        # Only grow small buffers, since repeatedly growing without writing
        # makes the buffer grow exponentially
        if r < 2 && length(get_buffer(io)) < 100
            n_before = length(get_buffer(io))
            n = grow_buffer(io)
            ok &= n > 0 && length(get_buffer(io)) == n_before + n
        elseif r < 3
            min_size = rand_below(60)
            buffer = get_nonempty_buffer(io, min_size)
            ok &= buffer !== nothing && length(buffer) ≥ max(min_size, 1)
        elseif r < 7
            # Write directly to the buffer
            buffer = get_buffer(io)
            n = rand_below(min(length(buffer), 100) + 1)
            data = UInt8[rand_below(256) for _ in 1:n]
            buffer = buffer[1:n]
            copyto!(buffer, data)
            consume(io, n)
            length(expected) < pos + n && resize!(expected, pos + n)
            expected[(pos + 1):(pos + n)] = data
            pos += n
        elseif r < 8
            data = UInt8[rand_below(256) for _ in 1:rand_below(40)]
            write(io, data)
            n = length(data)
            length(expected) < pos + n && resize!(expected, pos + n)
            expected[(pos + 1):(pos + n)] = data
            pos += n
        elseif r < 9
            flush(io)
            ok &= io.inner.data == expected
        else
            pos = rand_below(length(expected) + 1)
            seek(io, pos)
        end
        ok &= position(io) == pos
        ok &= filesize(io) == length(expected)
    end
    close(io)
    @test ok
    @test io.inner.data == expected
end

@testset "is_expandable for writers" begin
    @test BufferIO.is_expandable(BufWriter{IOBuffer})
    @test BufferIO.is_expandable(VecWriter)
    @test BufferIO.is_expandable(ExpandWriter{BlockWriter})
    @test BufferIO.is_expandable(ExpandWriter{BoundedWriter})
    # Default is false
    @test !BufferIO.is_expandable(BlockWriter)
    @test !BufferIO.is_expandable(BoundedWriter)
    @test !BufferIO.is_expandable(GenericBufWriter)
    @test !BufferIO.is_expandable(FixedWriter)
end

@testset "expandable for writers" begin
    # Expandable writers are returned unchanged
    for io in Any[BufWriter(IOBuffer()), VecWriter(), ExpandWriter(BlockWriter(4))]
        @test expandable(io) === io
        @test @inferred(expandable(io)) === io
    end

    # Other writers are wrapped
    sink = UInt8[]
    inner = BoundedWriter(sink, 2)
    io = @inferred expandable(inner)
    @test io isa ExpandWriter{BoundedWriter}
    @test io.inner === inner
    print(io, "abc", 123)
    flush(io)
    @test String(copy(sink)) == "abc123"

    # Idempotent
    io = expandable(BlockWriter(4))
    @test expandable(io) === io

    # Result can provide a buffer beyond inner's limit
    io = expandable(BoundedWriter(UInt8[], 3))
    @test length(get_nonempty_buffer(io, 100)) ≥ 100
end

@testset "get_inner" begin
    sink = UInt8[]
    inner = BoundedWriter(sink, 4)
    writer = ExpandWriter(inner)
    @test get_inner(writer) === inner
    # Getting the inner writer does not flush `writer`
    write(writer, "abc")
    @test get_inner(writer) === inner
    @test isempty(sink)
    # Nor does it disturb `writer` while it serves its own buffer
    buffer = get_nonempty_buffer(writer, 8)
    buffer[1:8] .= codeunits("defghijk")
    consume(writer, 8)
    @test get_inner(writer) === inner
    @test isopen(get_inner(writer))
    flush(writer)
    @test String(copy(sink)) == "abcdefghijk"

    @test isopen(writer)
    close(writer)
    @test_throws IOError get_inner(writer)

    writer = ExpandWriter(VecWriter())
    take_inner(writer)
    @test_throws IOError get_inner(writer)
end
