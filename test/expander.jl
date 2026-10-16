@testset "ExpandReader construction" begin
    # Test basic construction
    inner = BlockReader("hello", 2)
    io = ExpandReader(inner)
    @test io isa ExpandReader{BlockReader}
    @test io.inner === inner
    @test ExpandReader{BlockReader}(BlockReader("hello", 2)) isa ExpandReader{BlockReader}

    # Test initial state
    @test isempty(get_buffer(io))
    @test isopen(io)
    @test position(io) == 0
end

@testset "ExpandReader forwards inner buffer" begin
    # When inner can provide the bytes, its buffer is forwarded
    io = ExpandReader(BlockReader("abcdef", 4))
    @test fill_buffer(io) == 4
    @test get_buffer(io) === get_buffer(io.inner)
    @test !io.serving_own

    # Consuming is forwarded to inner
    consume(io, 3)
    @test String(get_buffer(io)) == "d"
    @test String(get_buffer(io.inner)) == "d"
    @test_throws IOError consume(io, 2)

    # Inner readers which never return nothing are simply forwarded
    io = ExpandReader(CursorReader("abc"))
    @test String(get_buffer(io)) == "abc"
    @test fill_buffer(io) == 0
    @test String(read(io)) == "abc"
end

@testset "ExpandReader expands buffer" begin
    io = ExpandReader(BlockReader("abcdefghij", 4))
    @test fill_buffer(io) == 4

    # Inner can't grow its buffer, so own buffer is used
    @test fill_buffer(io) == 4
    @test io.serving_own
    @test String(get_buffer(io)) == "abcdefgh"

    # Inner's buffer is fully copied, so inner must be filled
    @test fill_buffer(io) == 2
    @test String(get_buffer(io)) == "abcdefghij"

    # Filling at EOF when serving own buffer
    @test fill_buffer(io) == 0
    @test String(get_buffer(io)) == "abcdefghij"

    # Consuming from own buffer
    consume(io, 3)
    @test String(get_buffer(io)) == "defghij"
    @test_throws IOError consume(io, 8)
    @test_throws IOError consume(io, -1)
    @test String(read(io)) == "defghij"
    @test eof(io)
end

@testset "ExpandReader switches back to inner" begin
    # After consuming the bytes only in own buffer, inner's buffer has extra bytes,
    # which are returned without filling inner.
    io = ExpandReader(BlockReader("abcdefghijklmnopqrstuvwx", 8))
    fill_buffer(io)
    consume(io, 6)
    @test fill_buffer(io) == 6
    @test String(get_buffer(io)) == "ghijklmn"
    consume(io, 3)
    @test fill_buffer(io) == 2
    @test !io.serving_own
    @test String(get_buffer(io)) == "jklmnop"

    # After switching back, inner's buffer is empty, so inner is filled
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    consume(io, 8)
    @test fill_buffer(io) == 2
    @test !io.serving_own
    @test String(get_buffer(io)) == "ij"

    # After switching back, inner can't grow, so own buffer is used again,
    # reusing its existing memory.
    io = ExpandReader(BlockReader("0123456789ABCDEF", 4))
    fill_buffer(io)
    consume(io, 2)
    fill_buffer(io)
    mem = MemoryViews.memory(io.buffer)
    consume(io, 3)
    @test fill_buffer(io) == 4
    @test io.serving_own
    @test MemoryViews.memory(io.buffer) === mem
    @test String(get_buffer(io)) == "56789AB"
end

@testset "ExpandReader own buffer memory" begin
    # The own buffer is grown in place while it has room
    io = ExpandReader(BlockReader("abcdefghijklmnopqrstuvwxyz", 4))
    fill_buffer(io)
    fill_buffer(io)
    mem = MemoryViews.memory(io.buffer)
    fill_buffer(io)
    fill_buffer(io)
    @test String(get_buffer(io)) == "abcdefghijklmnop"
    @test MemoryViews.memory(io.buffer) === mem

    # If the own buffer can fit by moving its bytes to the start of memory, do that
    consume(io, 8)
    @test fill_buffer(io) == 4
    @test MemoryViews.memory(io.buffer) === mem
    @test String(get_buffer(io)) == "ijklmnopqrst"

    # Else, allocate new memory
    consume(io, 1)
    fill_buffer(io)
    @test MemoryViews.memory(io.buffer) === mem
    fill_buffer(io)
    @test MemoryViews.memory(io.buffer) !== mem
    @test String(get_buffer(io)) == "jklmnopqrstuvwxyz"
end

@testset "ExpandReader line_views" begin
    # Lines longer than inner's buffer
    s = "a\n" * "b"^100 * "\n\n" * "c"^30 * "\nd\n" * "e"^50
    io = ExpandReader(BlockReader(s, 7))
    @test [String(i) for i in line_views(io)] == split(s, '\n')

    # Short lines are mostly served from inner's buffer
    s = repeat("x"^19 * "\n", 100)
    io = ExpandReader(BlockReader(s, 400))
    n_own = 0
    for _ in line_views(io)
        n_own += io.serving_own
    end
    @test n_own < 10
end

@testset "ExpandReader position and filesize" begin
    io = ExpandReader(BlockReader("abcdefghij", 4))
    @test filesize(io) == 10

    # Position when serving inner
    fill_buffer(io)
    consume(io, 1)
    @test position(io) == 1

    # Position when serving own, with bytes consumed from inner not yet consumed by user
    fill_buffer(io)
    @test io.serving_own
    @test position(io) == 1
    consume(io, 2)
    @test position(io) == 3

    # Position when user has consumed into the debt
    consume(io, 4)
    @test position(io) == 7
    @test filesize(io) == 10
end

@testset "ExpandReader seek" begin
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    consume(io, 2)
    @test io.serving_own

    # Invalid seeks do not change the reader
    @test_throws IOError seek(io, 11)
    @test_throws IOError seek(io, -1)
    @test io.serving_own
    @test position(io) == 2
    @test String(get_buffer(io)) == "cdefgh"

    # Seeking switches back to inner
    seek(io, 1)
    @test !io.serving_own
    @test position(io) == 1
    @test String(read(io)) == "bcdefghij"
    seek(io, 10)
    @test eof(io)
end

@testset "ExpandReader relative_seek" begin
    # Relative seek when serving inner is forwarded
    io = ExpandReader(BlockReader("abcdefghijklmnopqrstuvwxyz", 4))
    relative_seek(io, 3)
    @test position(io) == 3
    @test_throws IOError relative_seek(io, -4)
    @test String(read(io, 2)) == "de"

    # Make io serve own buffer "abcdefghijklmnop", with inner buffer "mnop"
    io = ExpandReader(BlockReader("abcdefghijklmnopqrstuvwxyz", 4))
    for _ in 1:4
        fill_buffer(io)
    end
    @test String(get_buffer(io)) == "abcdefghijklmnop"

    # Seeking forward and backwards in memory
    consume(io, 5)
    relative_seek(io, -3)
    @test io.serving_own
    @test position(io) == 2
    @test String(get_buffer(io)) == "cdefghijklmnop"
    relative_seek(io, 4)
    @test io.serving_own
    @test String(get_buffer(io)) == "ghijklmnop"
    relative_seek(io, -6)
    @test String(get_buffer(io)) == "abcdefghijklmnop"

    # Invalid seeks do not change the reader
    @test_throws IOError relative_seek(io, -1)
    @test_throws IOError relative_seek(io, 27)
    @test io.serving_own
    @test position(io) == 0
    @test String(get_buffer(io)) == "abcdefghijklmnop"

    # Seeking beyond the own buffer seeks inner
    relative_seek(io, 20)
    @test !io.serving_own
    @test position(io) == 20
    @test String(read(io)) == "uvwxyz"

    # Seeking backwards from an empty own buffer seeks inner
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    consume(io, 8)
    @test io.serving_own
    relative_seek(io, -1)
    @test !io.serving_own
    @test String(read(io)) == "hij"

    # After compacting the own buffer, the bytes before it can't be seeked to in memory
    io = ExpandReader(BlockReader("abcdefghijklmnopqrstuvwxyz", 4))
    for _ in 1:4
        fill_buffer(io)
    end
    consume(io, 8)
    fill_buffer(io)
    relative_seek(io, -1)
    @test !io.serving_own
    @test String(read(io)) == "hijklmnopqrstuvwxyz"
end

@testset "ExpandReader close" begin
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    @test isopen(io)

    # Closing closes inner, and releases own buffer
    close(io)
    @test !isopen(io)
    @test io.inner.closed
    @test isempty(get_buffer(io))
    @test isempty(MemoryViews.memory(io.buffer))

    # Closing is idempotent
    close(io)
    @test !isopen(io)

    # Operations on closed reader
    consume(io, 0)
    @test_throws IOError consume(io, 1)
    @test_throws IOError fill_buffer(io)
    @test_throws IOError position(io)
    @test_throws IOError filesize(io)
    @test_throws IOError seek(io, 0)
    @test_throws IOError relative_seek(io, 0)
    err = try
        fill_buffer(io)
    catch e
        e
    end
    @test err.kind == IOErrorKinds.ClosedIO
end

@testset "ExpandReader take_inner" begin
    # Inner continues right after the buffer of `io`, which is discarded.
    # When forwarding inner's buffer, the buffer is consumed from inner.
    inner = BlockReader("abcdefghij", 4)
    io = ExpandReader(inner)
    fill_buffer(io)
    consume(io, 1)
    @test take_inner(io) === inner
    @test !isopen(io)
    @test !inner.closed
    @test String(read(inner)) == "efghij"

    # When serving own buffer, regardless of how much of the debt is consumed
    data = "abcdefghijklmnopqrstuvwxyz"
    for n_fills in 1:5
        probe = ExpandReader(BlockReader(data, 4))
        foreach(_ -> fill_buffer(probe), 1:n_fills)
        n_buffered = length(get_buffer(probe))
        for n_consumed in 0:n_buffered
            inner = BlockReader(data, 4)
            io = ExpandReader(inner)
            foreach(_ -> fill_buffer(io), 1:n_fills)
            @test io.serving_own == (n_fills > 1)
            consume(io, n_consumed)
            @test take_inner(io) === inner
            @test String(read(inner)) == data[(n_buffered + 1):end]
        end
    end

    # After take_inner, the reader can no longer access inner
    @test isempty(get_buffer(io))
    @test isempty(MemoryViews.memory(io.buffer))
    for f in [
            fill_buffer,
            r -> read(r, UInt8),
            position,
            filesize,
            r -> seek(r, 0),
            r -> relative_seek(r, 0),
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
    close(io)
    @test !inner.closed

    # Closed reader cannot be taken from
    io = ExpandReader(BlockReader("abc", 2))
    close(io)
    @test_throws IOError take_inner(io)
end

@testset "drop_own" begin
    # When own buffer is in use, it can't be dropped
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    mem = MemoryViews.memory(io.buffer)
    @test drop_own(io) === nothing
    @test MemoryViews.memory(io.buffer) === mem

    # When not in use, the own buffer is dropped and returned
    seek(io, 0)
    @test drop_own(io) === mem
    @test isempty(MemoryViews.memory(io.buffer))
    @test String(read(io)) == "abcdefghij"

    # After dropping, own buffer is allocated again as needed
    seek(io, 0)
    fill_buffer(io)
    fill_buffer(io)
    @test io.serving_own
    @test String(get_buffer(io)) == "abcdefgh"

    # Closed readers do not have an own buffer
    close(io)
    @test drop_own(io) === nothing
end

@testset "ExpandReader with invalid inner" begin
    # Inner returns nothing on an empty buffer
    io = ExpandReader(ScriptedReader("abcdefgh", 4))
    push!(io.inner.script, nothing)
    @test_throws ErrorException fill_buffer(io)

    # Inner returns nothing, even after its buffer has been emptied
    io = ExpandReader(ScriptedReader("abcdefgh", 4))
    fill_buffer(io)
    append!(io.inner.script, [nothing, nothing, nothing])
    @test_throws ErrorException fill_buffer(io)

    # Inner claims to fill, but buffer does not grow
    io = ExpandReader(ScriptedReader("abcdefgh", 4))
    fill_buffer(io)
    append!(io.inner.script, [nothing, 1])
    @test_throws ErrorException fill_buffer(io)

    # Inner is mutated, such that it does not contain the debt, while serving own buffer
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    consume(io.inner, 1)
    @test_throws ErrorException fill_buffer(io)

    # Inner is mutated, such that it does not contain the debt, when switching to inner
    io = ExpandReader(BlockReader("abcdefghij", 4))
    fill_buffer(io)
    fill_buffer(io)
    consume(io, 5)
    consume(io.inner, 2)
    @test_throws ErrorException fill_buffer(io)
end

@testset "ExpandReader randomized" begin
    # Simple PRNG to avoid depending on Random. Returns a number in 0:n-1
    state = UInt64(1)
    rand_below(n) = (state = state * 0x5851f42d4c957f2d + 0x14057b7ef767814f; Int((state >> 33) % n))

    # Random operations, compared against the expected position and buffer content
    data = [UInt8(rand_below(256)) for _ in 1:1000]
    io = ExpandReader(BlockReader(data, 13))
    pos = 0
    ok = true
    for _ in 1:2000
        r = rand_below(10)
        if r < 4
            fill_buffer(io)
        elseif r < 8
            n = rand_below(length(get_buffer(io)) + 1)
            consume(io, n)
            pos += n
        elseif r < 9
            delta = clamp(rand_below(101) - 50, -pos, 1000 - pos)
            relative_seek(io, delta)
            pos += delta
        else
            pos = rand_below(1001)
            seek(io, pos)
        end
        buffer = get_buffer(io)
        ok &= position(io) == pos
        ok &= buffer == view(data, (pos + 1):(pos + length(buffer)))
    end
    @test ok
end

@testset "is_expandable" begin
    @test BufferIO.is_expandable(BufReader{IOBuffer})
    @test BufferIO.is_expandable(CursorReader)
    @test BufferIO.is_expandable(ExpandReader{BlockReader})
    @test BufferIO.is_expandable(ExpandReader{BoundedReader})
    # Default is false
    @test !BufferIO.is_expandable(BlockReader)
    @test !BufferIO.is_expandable(BoundedReader)
    @test !BufferIO.is_expandable(GenericBufReader)
end

@testset "expandable" begin
    # Expandable readers are returned unchanged
    for io in Any[BufReader(IOBuffer("abc")), CursorReader("abc"), ExpandReader(BlockReader("abc", 1))]
        @test expandable(io) === io
        @test @inferred(expandable(io)) === io
    end

    # Other readers are wrapped
    inner = BoundedReader("abc\ndef", 2)
    io = @inferred expandable(inner)
    @test io isa ExpandReader{BoundedReader}
    @test io.inner === inner
    @test readline(io) == "abc"
    @test read(io, String) == "def"

    # Idempotent
    io = expandable(BlockReader("abc", 1))
    @test expandable(io) === io

    # Result can buffer beyond inner's limit
    io = expandable(BoundedReader("abcdefghij", 3))
    while !iszero(fill_buffer(io)::Int)
    end
    @test get_buffer(io) == b"abcdefghij"
end
